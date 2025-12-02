import SwiftUI
import SwiftData
import UniformTypeIdentifiers // 👈 1. 必须加上这一行，否则无法识别文件类型
struct BillHomeView: View {
    // 1. 拿到数据库上下文
    @Environment(\.modelContext) var context
    
    @Query(
        sort: [
            SortDescriptor(\Transaction.date, order: .reverse),
            SortDescriptor(\Transaction.merchant, order: .forward)
        ]
    )
    var dbTransactions: [Transaction]
    // 2. 控制弹窗
    @State private var selectedTransaction: Transaction? = nil
    @State private var transactionToEdit: Transaction?
    @State private var showDatePicker = false
    
    // 3. 筛选状态
    @State private var selectedDate = Date()
    @State private var showAll = false // 是否显示全部
    // 👇 2. 新增：控制趋势图弹窗
    @Query var cards: [CreditCard]
    @State private var showTrendSheet = false   // 控制“返现”弹窗
    @State private var showExpenseSheet = false // 👈 新增：控制“支出”弹窗
    // 👇 新增：导入相关状态
    @State private var showFileImporter = false
    @State private var showImportAlert = false
    @State private var importMessage = ""
    
    // 👇👇👇 补回缺失的状态：是否按整年筛选
    @State private var isWholeYear = false

    // 4. 汇率表
    @State private var exchangeRates: [String: Double] = [:]
    @State private var isLoadingRates = false
    @State private var rateError: String?
    
    // 5. 核心筛选逻辑 (升级版)
    var filteredTransactions: [Transaction] {
        if showAll { return dbTransactions }
        
        return dbTransactions.filter { t in
            if isWholeYear {
                // 👉 按“年”筛选 (只要年份相同)
                return Calendar.current.isDate(t.date, equalTo: selectedDate, toGranularity: .year)
            } else {
                // 👉 按“月”筛选 (年份和月份都相同)
                return Calendar.current.isDate(t.date, equalTo: selectedDate, toGranularity: .month)
            }
        }
    }
    
    // 辅助：按钮显示的文字
    var dateButtonText: String {
        if isWholeYear {
            // 显示 "2025年 全年"
            return selectedDate.formatted(.dateTime.year()) + " 全年"
        } else {
            // 显示 "2025年 11月"
            return selectedDate.formatted(.dateTime.year().month())
        }
    }
    
    // 计算总支出
    var totalExpense: Double {
        if exchangeRates.isEmpty { return 0.0 }
        return filteredTransactions.reduce(0) { total, t in
            let code = t.card?.issueRegion.currencyCode ?? "CNY"
            let rate = exchangeRates[code] ?? 1.0
            return total + (t.billingAmount / rate)
        }
    }
    
    // 计算总返现
    var totalCashback: Double {
        if exchangeRates.isEmpty { return 0.0 }
        return filteredTransactions.reduce(0) { total, t in
            let cb = CashbackService.calculateCashback(for: t)
            let code = t.card?.issueRegion.currencyCode ?? "CNY"
            let rate = exchangeRates[code] ?? 1.0
            return total + (cb / rate)
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        
                        // 1. 统计条 (标题动态变化)
                        HStack(spacing: 15) {
                            Button(action: {
                                showExpenseSheet = true // 点击触发支出弹窗
                            }) {
                                StatBox(
                                    title: showAll ? "总支出" : (isWholeYear ? "本年支出" : "本月支出"),
                                    amount: exchangeRates.isEmpty ? "..." : "¥\(String(format: "%.2f", totalExpense))",
                                    icon: "arrow.down.circle.fill", color: .red
                                )
                                .overlay(
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.gray.opacity(0.5))
                                        .padding(.trailing, 10),
                                    alignment: .trailing
                                )
                            }
                            .buttonStyle(.plain)
                            // 👇 3. 修改：给“总返现” StatBox 包裹一个 Button
                            Button(action: {
                                showTrendSheet = true // 点击触发弹窗
                            }) {
                                StatBox(
                                    title: showAll ? "总返现" : (isWholeYear ? "本年返现" : "本月返现"),
                                    amount: exchangeRates.isEmpty ? "..." : "¥\(String(format: "%.2f", totalCashback))",
                                    icon: "arrow.up.circle.fill", color: .green
                                )
                                // 添加一个小箭头暗示可以点击 (可选)
                                .overlay(
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.gray.opacity(0.5))
                                        .padding(.trailing, 10),
                                    alignment: .trailing
                                )
                            }
                            .buttonStyle(.plain) // 去掉按钮默认的点击变灰效果，保持 StatBox 原样
                        }
                        .padding(.horizontal).padding(.top)

                        if isLoadingRates {
                            ProgressView("正在更新汇率...")
                        } else if let rateError {
                            Text(rateError)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .padding(.horizontal)
                        }

                        // 2. 控制栏
                        HStack {
                            Text(showAll ? "全部账单" : (isWholeYear ? "年度账单" : "月度账单"))
                                .font(.headline).foregroundColor(.secondary)
                            
                            Spacer()
                            
                            HStack(spacing: 10) {
                                // "显示全部" 按钮
                                Button(action: { withAnimation { showAll = true } }) {
                                    Text("全部")
                                        .font(.subheadline)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(showAll ? Color.blue : Color.clear)
                                        .foregroundColor(showAll ? .white : .blue)
                                        .cornerRadius(8)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue, lineWidth: 1))
                                }
                                
                                // "选择日期" 按钮
                                Button(action: { showDatePicker = true }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "calendar")
                                        Text(dateButtonText) // 👈 使用动态文字
                                    }
                                    .font(.subheadline)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(showAll ? Color.clear : Color.blue)
                                    .foregroundColor(showAll ? .blue : .white)
                                    .cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue, lineWidth: 1))
                                }
                            }
                        }
                        .padding(.horizontal)
                        
                        // 3. 列表
                        LazyVStack(spacing: 15) {
                            ForEach(filteredTransactions) { item in
                                TransactionRow(transaction: item)
                                    .onTapGesture { selectedTransaction = item }
                                    .contextMenu {
                                        Button { transactionToEdit = item } label: { Label("编辑", systemImage: "pencil") }
                                        Button(role: .destructive) { context.delete(item) } label: { Label("删除", systemImage: "trash") }
                                    }
                            }
                            
                            if filteredTransactions.isEmpty {
                                ContentUnavailableView(
                                    "暂无账单",
                                    systemImage: "list.bullet.clipboard",
                                    description: Text("该时间段内没有交易记录")
                                )
                                .padding(.top, 40)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Cashback Counter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // 1. 导出选项
                        if !filteredTransactions.isEmpty,
                           let csvURL = filteredTransactions.exportCSVFile() {
                            ShareLink(item: csvURL) {
                                Label("导出账单", systemImage: "square.and.arrow.up")
                            }
                        }
                                                
                        // 2. 导入选项
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("导入账单", systemImage: "square.and.arrow.down")
                        }
                        
                    } label: {
                        // 外显图标：用圆圈三点或者之前的图标
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                        // .foregroundColor(.blue)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.commaSeparatedText], // 兼容 .csv
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    // 安全访问
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    
                    do {
                        let content = try String(contentsOf: url, encoding: .utf8)
                        // 调用刚才写的 Helper，传入 context 和当前的卡片列表
                        try CSVHelper.parseTransactionCSV(content: content, context: context, allCards: cards)
                        
                        importMessage = "导入成功！"
                        showImportAlert = true
                    } catch {
                        importMessage = "导入失败：\(error.localizedDescription)"
                        showImportAlert = true
                    }
                case .failure(let error):
                    print("选择文件失败: \(error)")
                }
            }
            // 结果提示框
            .alert("导入结果", isPresented: $showImportAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(importMessage)
            }
        
            // 弹窗绑定
            .sheet(item: $selectedTransaction) { item in
                TransactionDetailView(transaction: item).presentationDetents([.large])
            }
            .sheet(item: $transactionToEdit) { item in
                AddTransactionView(transaction: item)
            }
            // 👇👇👇 修复：绑定 MonthYearPicker 并传入 isWholeYear
            .sheet(isPresented: $showDatePicker) {
                MonthYearPicker(date: $selectedDate, isWholeYear: $isWholeYear)
                    .presentationDetents([.height(300)])
                    .onDisappear { withAnimation { showAll = false } }
            }
            .sheet(isPresented: $showTrendSheet) {
                TrendAnalysisView(
                    transactions: dbTransactions,
                    cards: cards,
                    exchangeRates: exchangeRates,
                    type: .cashback // 👈 指定为返现模式 (绿色)
                )
                .presentationDetents([.large, .large])
                .presentationDragIndicator(.visible)
            }

            // 👇 2. 新增：支出分析弹窗
            .sheet(isPresented: $showExpenseSheet) {
                TrendAnalysisView(
                    transactions: dbTransactions,
                    cards: cards,
                    exchangeRates: exchangeRates,
                    type: .expense // 👈 指定为支出模式 (红色)
                )
                .presentationDetents([.large, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .task { await refreshRates() }
        .refreshable { await refreshRates() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { Task { await refreshRates() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoadingRates)
            }
        }
    }
}

private extension BillHomeView {
    func refreshRates() async {
        await MainActor.run {
            isLoadingRates = true
            rateError = nil
        }

        let rates = await CurrencyService.getRates(base: "CNY")
        await MainActor.run {
            exchangeRates = rates.isEmpty ? ["CNY": 1.0] : rates
            if rates.isEmpty {
                rateError = "汇率获取失败，已使用 1.0 作为默认值"
            }
            isLoadingRates = false
        }
    }
}

