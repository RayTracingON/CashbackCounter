import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct StatementAnalysisEntryView: View {
    @State private var showImporter = false
    @State private var statement: StatementMetadata?
    @State private var statementVersion = 0
    @State private var errorMessage: String?
    @State private var isParsing = false

    var body: some View {
        NavigationView {
            Group {
                if let statement {
                    StatementAnalysisView(statement: statement)
                        .id(statementVersion)
                } else {
                    ContentUnavailableView(
                        "尚未导入结单",
                        systemImage: "chart.bar.doc.horizontal",
                        description: Text("上传结单PDF以开始对账")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .overlay { parsingOverlay }
            .navigationTitle("结单分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        StatementDebugLogger.log("Tap upload statement")
                        showImporter = true
                    } label: {
                        Label("上传结单", systemImage: "square.and.arrow.down")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            StatementDebugLogger.log("fileImporter result received")
            switch result {
            case .success(let urls):
                StatementDebugLogger.log("fileImporter success urls=\(urls.count)")
                guard let url = urls.first else { return }
                StatementDebugLogger.log("fileImporter selected url=\(url.lastPathComponent)")
                guard url.startAccessingSecurityScopedResource() else {
                    StatementDebugLogger.log("startAccessingSecurityScopedResource failed")
                    errorMessage = "无法读取文件权限"
                    return
                }
                StatementDebugLogger.log("startAccessingSecurityScopedResource ok")
                isParsing = true
                StatementDebugLogger.log("set isParsing=true")
                Task {
                    StatementDebugLogger.log("parse task started")
                    defer {
                        url.stopAccessingSecurityScopedResource()
                        StatementDebugLogger.log("stopAccessingSecurityScopedResource")
                    }
                    let metadata = await StatementParser().parse(from: url)
                    await MainActor.run {
                        if let metadata {
                            statement = metadata
                            statementVersion += 1
                            StatementDebugLogger.log("parse success transactions=\(metadata.transactions.count)")
                        } else {
                            errorMessage = "解析失败"
                            StatementDebugLogger.log("parse failed: metadata nil")
                        }
                        isParsing = false
                        StatementDebugLogger.log("set isParsing=false")
                    }
                }
            case .failure(let error):
                errorMessage = "选择文件失败：\(error.localizedDescription)"
                StatementDebugLogger.log("fileImporter failure: \(error.localizedDescription)")
            }
        }
        .alert("导入失败", isPresented: errorBinding) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var parsingOverlay: some View {
        if isParsing {
            ProgressView("解析中...")
                .padding(16)
                .background(.ultraThinMaterial)
                .cornerRadius(DesignConstants.CornerRadius.large)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { newValue in
                if !newValue {
                    errorMessage = nil
                }
            }
        )
    }
}

struct StatementAnalysisView: View {
    @AppStorage("mainCurrencyCode") private var mainCurrencyCode: String = "CNY"
    let statement: StatementMetadata

    @Query private var transactions: [Transaction]
    @Query(sort: [
        SortDescriptor(\CreditCard.bankName, order: .forward),
        SortDescriptor(\CreditCard.type, order: .forward),
        SortDescriptor(\CreditCard.endNum, order: .forward)
    ])
    private var cards: [CreditCard]
    
    @State private var viewModel = StatementAnalysisViewModel()

    private var report: ReconciliationReport {
        viewModel.report(statement: statement, transactions: transactions, cards: cards)
    }

    /// 账单金额的记账货币。选中卡的发卡地区说了算，没选卡时退回主货币。
    ///
    /// 必须显式告诉 NumberFormatter 用哪个货币：只给它一个 locale 的话，
    /// 货币符号就跟着 App 语言走，同一份英镑账单切成中文会变成 ¥。
    private var billingCurrencyCode: String {
        viewModel.selectedCard(cards: cards)?.issueRegion.currencyCode ?? mainCurrencyCode
    }

    var body: some View {
        VStack(spacing: 12) {
            StatementSummaryCard(
                metadata: statement,
                report: report,
                cards: cards,
                selectedCardIndex: $viewModel.selectedCardIndex,
                detectedCardText: viewModel.detectedCardText,
                isDetectingCard: viewModel.isDetectingCard,
                isAnalyzingTransactions: viewModel.isAnalyzingTransactions,
                currencyCode: billingCurrencyCode
            )
                .padding(.horizontal)

            List {
                Section(header: missingHeader) {
                    if report.missingInApp.isEmpty {
                        Text("No missing transactions")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(report.missingInApp) { item in
                            ReconciliationRow(
                                transaction: item,
                                status: .missing,
                                onAdd: { viewModel.selectedMissing = item },
                                currencyCode: billingCurrencyCode
                            )
                        }
                    }
                }

                Section(header: matchedHeader) {
                    if report.matched.isEmpty {
                        Text("No matched transactions")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(report.matched) { item in
                            ReconciliationRow(
                                transaction: item,
                                status: .matched,
                                onAdd: nil,
                                currencyCode: billingCurrencyCode
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Statement Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            StatementDebugLogger.log("StatementAnalysisView task start")
            await viewModel.detectStatementCardIfNeeded(statement: statement)
            await viewModel.autoAnalyzeIfNeeded(statement: statement, existingTransactions: transactions, cards: cards)
            StatementDebugLogger.log("StatementAnalysisView task end")
        }
        .onChange(of: cards.count) { _, _ in
            StatementDebugLogger.log("cards count changed: \(cards.count)")
            if let selectedCardIndex = viewModel.selectedCardIndex, !cards.indices.contains(selectedCardIndex) {
                viewModel.selectedCardIndex = nil
            }
            viewModel.applyDetectedCardSelectionIfNeeded(cards: cards)
        }
        .onChange(of: viewModel.detectedCardLast4) { _, _ in
            viewModel.applyDetectedCardSelectionIfNeeded(cards: cards)
        }
        .onChange(of: viewModel.detectedCardName) { _, _ in
            viewModel.applyDetectedCardSelectionIfNeeded(cards: cards)
        }
        .sheet(item: $viewModel.selectedMissing) { item in
            let selectedCard = viewModel.selectedCard(cards: cards)
            AddTransactionView(
                transaction: nil,
                image: nil,
                prefillMerchant: item.merchant,
                prefillAmount: item.foreignAmount ?? item.billingAmount,
                prefillBillingAmount: item.billingAmount,
                prefillDate: item.transactionDate,
                prefillCategory: item.category,
                prefillLocation: item.region,
                prefillPaymentMethod: item.paymentMethod,
                prefillCardLast4: selectedCard?.endNum,
                onSaved: nil
            )
        }
    }

    private var missingHeader: some View {
        Text("Missing in App (Action Required)")
            .foregroundColor(.orange)
    }

    private var matchedHeader: some View {
        Text("Already Recorded")
            .foregroundColor(.green)
    }
}

private struct StatementSummaryCard: View {
    let metadata: StatementMetadata
    let report: ReconciliationReport
    let cards: [CreditCard]
    @Binding var selectedCardIndex: Int?
    let detectedCardText: String?
    let isDetectingCard: Bool
    let isAnalyzingTransactions: Bool
    let currencyCode: String

    private var totalCount: Int {
        metadata.transactions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statement Summary")
                .font(.headline)
                .foregroundColor(.secondary)

            Text(balanceText)
                .font(.title)
                .fontWeight(.bold)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Matched: \(report.matched.count) items")
                        .font(.subheadline)
                    Text("Missing: \(report.missingInApp.count) items")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }

                Spacer()
            }

            if cards.isEmpty {
                Text("请先添加信用卡")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack {
                    Text("结单卡")
                        .font(.subheadline)
                    Spacer()
                    Picker("结单卡", selection: $selectedCardIndex) {
                        Text("请选择")
                            .tag(Int?.none)
                        ForEach(cards.indices, id: \.self) { index in
                            let card = cards[index]
                            Text("\(card.bankName) \(card.type)")
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .truncationMode(.middle)
                                .tag(index as Int?)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            if let detectedCardText, !detectedCardText.isEmpty {
                HStack(spacing: 6) {
                    if isDetectingCard {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Text("自动识别: \(detectedCardText)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if isDetectingCard {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("正在识别结单卡...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if isAnalyzingTransactions {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("识别交易中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.blue.opacity(0.1))
        )
    }

    private var balanceText: String {
        guard let total = metadata.totalBalance else { return "--" }
        return formatAmount(total)
    }

    private func formatAmount(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = AppLanguage.locale
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }
}

private struct ReconciliationRow: View {
    enum Status {
        case missing
        case matched
    }

    let transaction: ImportedTransaction
    let status: Status
    let onAdd: (() -> Void)?
    let currencyCode: String

    var body: some View {
        HStack(spacing: 12) {
            DateBadge(date: transaction.transactionDate)

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchant)
                    .font(.body)
                    .lineLimit(1)

                if let foreignText = foreignAmountText {
                    Text(foreignText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let analysisText = analysisDetailText {
                    Text(analysisText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(formatAmount(transaction.billingAmount))
                    .fontWeight(.semibold)

                switch status {
                case .missing:
                    Button {
                        onAdd?()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                    }
                case .matched:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                }
            }
        }
        .opacity(status == .matched ? 0.6 : 1)
        .padding(.vertical, 4)
    }

    private var foreignAmountText: String? {
        guard let amount = transaction.foreignAmount,
              let currency = transaction.region?.currencyCode else {
            return nil
        }
        return "\(currency) \(String(format: "%.2f", amount))"
    }

    private var analysisDetailText: String? {
        var parts: [String] = []
        if let region = transaction.region {
            parts.append("\(region.icon) \(region.rawValue)")
        }
        if let paymentMethod = transaction.paymentMethod {
            parts.append(paymentMethod.displayName)
        }
        if let category = transaction.category {
            parts.append(category.displayName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatAmount(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = AppLanguage.locale
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }
}

private struct DateBadge: View {
    let date: Date

    var body: some View {
        VStack(spacing: 2) {
            Text(Self.dayFormatter.string(from: date))
                .font(.headline)
            Text(Self.monthFormatter.string(from: date))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(width: 44)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
        )
    }

    // 用计算属性而不是 static let：static let 只在首次访问时算一次，
    // 之后在设置里切语言，月份缩写会一直卡在旧语言（"9月" / "Sep"）。
    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateFormat = "d"
        return formatter
    }

    private static var monthFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateFormat = "MMM"
        return formatter
    }
}

// MARK: - Previews

#if DEBUG
#Preview("结单分析 · 入口（未导入）") {
    StatementAnalysisEntryView()
        .previewEnvironment()
}

#Preview("结单分析 · 已解析") {
    NavigationStack {
        StatementAnalysisView(statement: PreviewData.statement)
    }
    .previewEnvironment()
}

#Preview("结单分析 · 本地无交易可对账") {
    // 对账两侧都空时应给出可理解的结果，而不是一屏"缺失"
    NavigationStack {
        StatementAnalysisView(statement: PreviewData.statement)
    }
    .previewEmptyEnvironment()
}

#Preview("结单摘要卡", traits: .sizeThatFitsLayout) {
    @Previewable @State var selectedCardIndex: Int? = 1
    StatementSummaryCard(metadata: PreviewData.statement,
                         report: PreviewData.reconciliationReport,
                         cards: PreviewData.cards,
                         selectedCardIndex: $selectedCardIndex,
                         detectedCardText: "识别到尾号 1234（HSBC HK Red Card）",
                         isDetectingCard: false,
                         isAnalyzingTransactions: false,
                         currencyCode: "HKD")
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
        .previewEnvironment()
}

#Preview("结单摘要卡 · 识别中", traits: .sizeThatFitsLayout) {
    // 两个 loading 标志同时为 true：转圈和"分析中"文案都该出现
    @Previewable @State var selectedCardIndex: Int? = nil
    StatementSummaryCard(metadata: PreviewData.statement,
                         report: PreviewData.reconciliationReport,
                         cards: PreviewData.cards,
                         selectedCardIndex: $selectedCardIndex,
                         detectedCardText: nil,
                         isDetectingCard: true,
                         isAnalyzingTransactions: true,
                         currencyCode: "HKD")
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
        .previewEnvironment()
}

#Preview("对账行", traits: .sizeThatFitsLayout) {
    let items = PreviewData.importedTransactions
    List {
        // 缺失：右侧有"添加"按钮
        ReconciliationRow(transaction: items[0], status: .missing,
                          onAdd: {}, currencyCode: "HKD")
        // 已匹配：不给添加入口
        ReconciliationRow(transaction: items[1], status: .matched,
                          onAdd: nil, currencyCode: "HKD")
        // 带外币折算的那笔
        ReconciliationRow(transaction: items[2], status: .missing,
                          onAdd: {}, currencyCode: "HKD")
    }
}

#Preview("日期徽标", traits: .sizeThatFitsLayout) {
    HStack(spacing: 12) {
        DateBadge(date: Date())
        DateBadge(date: Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date())
    }
    .padding()
}
#endif
