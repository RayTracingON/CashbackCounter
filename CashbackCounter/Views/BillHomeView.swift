import SwiftUI
import SwiftData
import UniformTypeIdentifiers // 确保引入以支持文件导入

struct BillHomeView: View {
    @State private var searchText = ""
    @State private var isSearchPresented = false

    var body: some View {
        BillHomeContentView(searchText: $searchText, isSearchPresented: $isSearchPresented)
    }
}

struct BillHomeContentView: View {
    // 1. 数据库上下文
    @Environment(\.modelContext) var context
    
    // 按日期倒序、商户名正序排列
    @Query private var dbTransactions: [Transaction]
    
    // 2. ViewModel
    @State private var viewModel = BillHomeViewModel()
    
    // 👇 搜索状态
    @Binding private var searchText: String
    @Binding private var isSearchPresented: Bool

    // 趋势图数据
    @Query var cards: [CreditCard]

    // 4. 汇率表
    @AppStorage("mainCurrencyCode") private var mainCurrencyCode: String = "CNY"
    
    init(searchText: Binding<String>, isSearchPresented: Binding<Bool>) {
        let trimmed = searchText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        _searchText = searchText
        _isSearchPresented = isSearchPresented

        if trimmed.isEmpty {
            _dbTransactions = Query(
                sort: [
                    SortDescriptor(\Transaction.date, order: .reverse),
                    SortDescriptor(\Transaction.merchant, order: .forward)
                ]
            )
        } else {
            _dbTransactions = Query(
                filter: #Predicate<Transaction> { transaction in
                    transaction.merchant.localizedStandardContains(trimmed)
                },
                sort: [
                    SortDescriptor(\Transaction.date, order: .reverse),
                    SortDescriptor(\Transaction.merchant, order: .forward)
                ]
            )
        }
    }

    // 5. 核心筛选逻辑 (委托给 ViewModel)
    var filteredTransactions: [Transaction] {
        viewModel.filteredTransactions(from: dbTransactions, searchText: searchText, isSearchPresented: isSearchPresented)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearchingActive: Bool {
        !trimmedSearchText.isEmpty
    }

    private var isSearchFieldActive: Bool {
        isSearchPresented || isSearchingActive
    }

    @ViewBuilder
    private var filterBar: some View {
        if !isSearchFieldActive {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // 左侧留白
                    Spacer().frame(width: 16)
                    
                    // A. 类别筛选
                    Menu {
                        Button(action: { viewModel.selectedCategory = nil }) {
                            Label("全部种类", systemImage: "checkmark.circle")
                        }
                        ForEach(Category.allCases, id: \.self) { category in
                            Button(action: { viewModel.selectedCategory = category }) {
                                Label(category.displayName, systemImage: category.iconName)
                            }
                        }
                    } label: {
                        FilterChip(
                            title: viewModel.selectedCategory?.displayName ?? String(localized: "全部种类"),
                            icon: viewModel.selectedCategory?.iconName ?? "line.3.horizontal.decrease.circle",
                            isSelected: viewModel.selectedCategory != nil
                        )
                    }

                    // B. 收入筛选
                    Button(action: { viewModel.showIncomeOnly.toggle() }) {
                        FilterChip(
                            title: String(localized: "收入单"),
                            icon: "tray.and.arrow.down.fill",
                            isSelected: viewModel.showIncomeOnly
                        )
                    }

                    // C. 日期筛选
                    Button(action: { viewModel.showDatePicker = true }) {
                        FilterChip(
                            title: viewModel.dateButtonText,
                            icon: "calendar",
                            isSelected: !viewModel.showAll
                        )
                    }
                    
                    // 右侧留白
                    Spacer().frame(width: 16)
                }
            }
        }
    }

    @ViewBuilder
    private var statsBar: some View {
        HStack(spacing: DesignConstants.Spacing.statsSpacing) {
            // 支出统计 -> 红色趋势图
            Button(action: { viewModel.showExpenseSheet = true }) {
                StatBox(
                    title: viewModel.expenseTitle(isSearchingActive: isSearchingActive),
                    amount: viewModel.exchangeRates.isEmpty ? "..." : String(format: "%.2f", viewModel.totalExpense(from: filteredTransactions, mainCurrencyCode: mainCurrencyCode)),
                    icon: "arrow.down.circle.fill", color: .red
                )
                .overlay(
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundColor(.gray.opacity(0.5)).padding(.trailing, 10),
                    alignment: .trailing
                )
            }
            .buttonStyle(.plain)
            
            // 返现统计 -> 绿色趋势图
            Button(action: { viewModel.showTrendSheet = true }) {
                StatBox(
                    title: viewModel.cashbackTitle(isSearchingActive: isSearchingActive),
                    amount: viewModel.exchangeRates.isEmpty ? "..." : String(format: "%.2f", viewModel.totalCashback(from: filteredTransactions, mainCurrencyCode: mainCurrencyCode)),
                    icon: "arrow.up.circle.fill", color: .green
                )
                .overlay(
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundColor(.gray.opacity(0.5)).padding(.trailing, 10),
                    alignment: .trailing
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.top)
    }

    @ViewBuilder
    private var transactionList: some View {
        LazyVStack(spacing: DesignConstants.Spacing.listItemSpacing) {
            ForEach(filteredTransactions) { item in
                VStack(alignment: .leading, spacing: 8) {
                    TransactionRow(transaction: item, exchangeRates: viewModel.exchangeRates)
                        .onTapGesture { viewModel.selectedTransaction = item }
                        .contextMenu {
                            Button { viewModel.transactionToEdit = item } label: { Label("编辑", systemImage: "pencil") }
                            Button { viewModel.incomeTargetTransaction = item } label: { Label("添加收入", systemImage: "plus.rectangle.on.rectangle") }
                            Divider()
                            Button(role: .destructive) { viewModel.deleteTransaction(item, context: context) } label: { Label("删除", systemImage: "trash") }
                        }
                    
                    // 显示关联收入
                    if let incomes = item.incomes, !incomes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(incomes.sorted(by: { $0.date > $1.date })) { income in
                                IncomeRow(income: income)
                                    .contextMenu {
                                        Button { viewModel.incomeToEdit = income } label: { Label("编辑收入", systemImage: "pencil") }
                                        Button(role: .destructive) {
                                            viewModel.deleteIncome(income, context: context)
                                        } label: { Label("删除", systemImage: "trash") }
                                    }
                            }
                        }
                        .padding(.leading, 30)
                    }
                }
            }
            
            // 空状态提示
            if filteredTransactions.isEmpty {
                ContentUnavailableView(
                    LocalizedStringKey(isSearchingActive ? "未找到结果" : "暂无账单"),
                    systemImage: isSearchingActive ? "magnifyingglass" : "list.bullet.clipboard",
                    description: Text(isSearchingActive ? "尝试更换关键词" : "该筛选条件下没有交易记录")
                )
                .padding(.top, 40)
            }
        }
        .padding(.horizontal)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: DesignConstants.Spacing.sectionSpacing) {
                        
                        // 1. 统计条 (点击数字可查看趋势)
                        statsBar
                        
                        // 2. 控制栏 (筛选器) - 使用 ScrollView 优化布局
                        filterBar
                        
                        // 3. 交易列表
                        transactionList
                    }
                }
            }
            .navigationTitle("Cashback Counter")
            .navigationBarTitleDisplayMode(.inline)
            // 👇 新增：搜索框
            .searchable(text: $searchText, isPresented: $isSearchPresented, placement: .automatic, prompt: "搜索商户")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // 导出（延迟到按钮点击时才生成 ZIP，避免在视图构建时阻塞主线程）
                        if !filteredTransactions.isEmpty {
                            Button {
                                let transactions = filteredTransactions
                                viewModel.exportedFileURL = transactions.exportReceiptsZip()
                            } label: {
                                Label("导出账单", systemImage: "square.and.arrow.up")
                            }
                        }
                        
                        // 导入
                        Button { viewModel.showFileImporter = true } label: {
                            Label("导入账单", systemImage: "square.and.arrow.down")
                        }
                        Button { viewModel.showStatementAnalysis = true } label: {
                            Label("导入结单", systemImage: "chart.bar.doc.horizontal.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: DesignConstants.FontSize.toolbarIcon))
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.exportedFileURL != nil },
                set: { if !$0 { viewModel.exportedFileURL = nil } }
            )) {
                if let url = viewModel.exportedFileURL {
                    ActivityViewController(activityItems: [url])
                }
            }

            // 文件导入器
            .fileImporter(
                isPresented: $viewModel.showFileImporter,
                allowedContentTypes: [.commaSeparatedText, .zip],
                allowsMultipleSelection: false
            ) { result in
                viewModel.handleFileImport(result: result, context: context, cards: cards)
            }
            .alert("导入结果", isPresented: $viewModel.showImportAlert) {
                Button("确定", role: .cancel) { }
            } message: { Text(viewModel.importMessage) }
            
            // 各类 Sheet 弹窗
            .sheet(item: $viewModel.selectedTransaction) { item in
                TransactionDetailView(transaction: item).presentationDetents([.large])
            }
            .sheet(item: $viewModel.incomeTargetTransaction) { transaction in
                AddIncomeView(transaction: transaction)
            }
            .sheet(item: $viewModel.incomeToEdit) { income in
                EditIncomeView(income: income)
            }
            .sheet(item: $viewModel.transactionToEdit) { item in
                AddTransactionView(transaction: item)
            }
            .sheet(isPresented: $viewModel.showDatePicker) {
                MonthYearPicker(date: $viewModel.selectedDate, isWholeYear: $viewModel.isWholeYear)
                    .presentationDetents([.height(300)])
                    .onDisappear { withAnimation { viewModel.showAll = false } }
            }
            .sheet(isPresented: $viewModel.showTrendSheet) {
                TrendAnalysisView(transactions: dbTransactions, cards: cards, exchangeRates: viewModel.exchangeRates, type: .cashback)
                    .presentationDetents([.large, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $viewModel.showExpenseSheet) {
                TrendAnalysisView(transactions: dbTransactions, cards: cards, exchangeRates: viewModel.exchangeRates, type: .expense)
                    .presentationDetents([.large, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $viewModel.showStatementAnalysis) {
                StatementAnalysisEntryView()
            }
        }
        .task {
            await viewModel.loadExchangeRates(mainCurrencyCode: mainCurrencyCode)
            viewModel.logNegativeExpenseTransactions(filteredTransactions: filteredTransactions, mainCurrencyCode: mainCurrencyCode)
        }
        .onChange(of: mainCurrencyCode) { _, newCode in
            Task {
                await viewModel.loadExchangeRates(mainCurrencyCode: newCode)
                viewModel.logNegativeExpenseTransactions(filteredTransactions: filteredTransactions, mainCurrencyCode: mainCurrencyCode)
            }
        }
        .onAppear {
            Task { @MainActor in
                await CardTemplateManager.shared.syncTemplates()
                do {
                    try CardTemplateManager.shared.refreshCardsFromTemplates(in: context)
                } catch {
                    print("Failed to refresh cards from templates: \(error)")
                }
            }
        }
    }
}

// MARK: - 抽取出的通用筛选按钮组件
struct FilterChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.subheadline)
        .padding(.horizontal, DesignConstants.Spacing.chipSpacing).padding(.vertical, 5)
        .background(isSelected ? Color.blue : Color.clear)
        .foregroundColor(isSelected ? .white : .blue)
        .cornerRadius(DesignConstants.CornerRadius.medium)
        .overlay(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium).stroke(Color.blue, lineWidth: 1))
    }
}
