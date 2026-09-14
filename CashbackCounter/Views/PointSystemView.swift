import SwiftUI
import SwiftData
import Charts

struct PointSystemView: View {
    @Query(sort: [SortDescriptor(\Transaction.date, order: .reverse)])
    private var transactions: [Transaction]

    @Query(sort: [SortDescriptor(\PointAdjustment.date, order: .reverse)])
    private var adjustments: [PointAdjustment]

    @Query(sort: [SortDescriptor(\CreditCard.bankName, order: .forward)])
    private var cards: [CreditCard]

    @AppStorage("mainCurrencyCode") private var mainCurrencyCode: String = "CNY"
    @State private var viewModel = PointSystemViewModel()

    var body: some View {
        let summaries = viewModel.pointSummaries(transactions: transactions, adjustments: adjustments, cards: cards)
        let totalValue = viewModel.totalEstimatedValue(for: summaries, mainCurrencyCode: mainCurrencyCode)

        NavigationView {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        dashboardHeader(totalValue: totalValue)

                        pointCardSection(summaries: summaries)
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("积分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(action: { viewModel.showPointLibrary = true }) {
                            Label("积分库", systemImage: "star.circle")
                        }
                        Button(action: { viewModel.showPointAdjustment = true }) {
                            Label("手动添加积分", systemImage: "plus")
                        }
                        Button(action: { viewModel.showPointRemoval = true }) {
                            Label("手动移除积分", systemImage: "minus")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 24))
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showPointLibrary) {
            PointLibraryView()
        }
        .sheet(isPresented: $viewModel.showPointAdjustment) {
            PointAdjustmentEntryView()
        }
        .sheet(isPresented: $viewModel.showPointRemoval) {
            PointRemovalEntryView()
        }
        .task {
            await viewModel.refreshRates(mainCurrencyCode: mainCurrencyCode)
        }
        .onChange(of: mainCurrencyCode) { _, _ in
            Task { await viewModel.refreshRates(mainCurrencyCode: mainCurrencyCode) }
        }
    }

    @ViewBuilder
    private func dashboardHeader(totalValue: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("总等值价值")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("预估")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                    )

                Spacer()

                Image(systemName: "star.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            Text(viewModel.isRatesReady ? viewModel.formattedCurrency(totalValue, code: mainCurrencyCode) : "...")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .monospacedDigit()

            HStack(spacing: 8) {
                if viewModel.isRatesReady {
                    Text("按 \(mainCurrencyCode) 计价")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("汇率获取中")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 22, tint: .accentColor)
    }

    @ViewBuilder
    private func pointCardSection(summaries: [PointProgramSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("积分卡片")
                    .font(.headline)

                Spacer()

                if !summaries.isEmpty {
                    Text("\(summaries.count) 个计划")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)

            if summaries.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "暂无积分记录",
                        systemImage: "star.circle",
                        description: Text("新增积分返现交易后，这里会显示累计积分")
                    )

                    HStack(spacing: 12) {
                        Button(action: { viewModel.showPointLibrary = true }) {
                            Label("添加积分计划", systemImage: "star.circle")
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: { viewModel.showPointAdjustment = true }) {
                            Label("手动添加", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(summaries) { summary in
                        NavigationLink {
                            PointDetailView(
                                summary: summary,
                                transactions: transactions,
                                adjustments: adjustments,
                                exchangeRates: viewModel.exchangeRates,
                                mainCurrencyCode: mainCurrencyCode
                            )
                        } label: {
                            PointSummaryCard(
                                summary: summary,
                                pointsText: viewModel.formattedPoints(summary.points)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct CardSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))

                    if let tint {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [tint.opacity(0.18), tint.opacity(0.0)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

private extension View {
    func cardSurface(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, tint: tint))
    }
}

private struct PointSummaryCard: View {
    let summary: PointProgramSummary
    let pointsText: String

    var body: some View {
        HStack(spacing: 14) {
            PointLogoPlaceholder(
                bankName: summary.bankName,
                colors: summary.themeColors
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.bankName)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !summary.pointName.isEmpty {
                    Text(summary.pointName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(pointsText)
                    .font(.title3.weight(.bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                Text("积分")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary.opacity(0.8))
        }
        .padding(16)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .cornerRadius(DesignConstants.CornerRadius.pill)
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 4)
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))

            if !summary.themeColors.isEmpty {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: summary.themeColors.map { $0.opacity(0.22) },
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
    }
}

private struct PointLogoPlaceholder: View {
    let bankName: String
    let colors: [Color]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(String(bankName.prefix(1)).uppercased())
                .font(.headline)
                .foregroundColor(.white)
        }
        .frame(width: 48, height: 48)
    }

    private var gradientColors: [Color] {
        if colors.isEmpty {
            return [Color.gray.opacity(0.6), Color.gray.opacity(0.3)]
        }
        return colors
    }
}

private struct PointDetailView: View {
    let summary: PointProgramSummary
    let transactions: [Transaction]
    let adjustments: [PointAdjustment]
    let exchangeRates: [String: Double]
    let mainCurrencyCode: String

    private var accentColor: Color {
        summary.themeColors.first ?? .blue
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                chartCard
                historyCard
            }
            .padding()
        }
        .navigationTitle("积分明细")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PointLogoPlaceholder(
                    bankName: summary.bankName,
                    colors: summary.themeColors
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.bankName)
                        .font(.headline)
                    if !summary.pointName.isEmpty {
                        Text(summary.pointName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前积分")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formattedPoints(totalPoints))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("估算价值")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(isRatesReady ? formattedCurrency(estimatedValue, code: mainCurrencyCode) : "...")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .padding(16)
        .cardSurface(cornerRadius: 16, tint: accentColor)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("近6个月积分变化")
                .font(.headline)
            Text("净变化：\(formattedPoints(netPoints)) 积分")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()

            Chart(chartData) { item in
                LineMark(
                    x: .value("月份", item.date, unit: .month),
                    y: .value("积分", item.points)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(accentColor)
                .lineStyle(StrokeStyle(lineWidth: 3))

                AreaMark(
                    x: .value("月份", item.date, unit: .month),
                    y: .value("积分", item.points)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [accentColor.opacity(0.3), accentColor.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                PointMark(
                    x: .value("月份", item.date, unit: .month),
                    y: .value("积分", item.points)
                )
                .foregroundStyle(accentColor)
                .symbolSize(40)
            }
            .frame(height: 240)
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel(format: .dateTime.month(), centered: true)
                        .font(.caption)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
        }
        .padding(16)
        .cardSurface(cornerRadius: 16)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("积分变动明细")
                .font(.headline)
                .padding(.bottom, 8)
            
            if historyItems.isEmpty {
                Text("暂无积分变动记录")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(historyItems) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.iconSystemName)
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(item.iconColor)
                            .clipShape(Circle())
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(item.date, style: .date)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Text("\(item.points > 0 ? "+" : "")\(formattedPoints(item.points))")
                            .font(.headline)
                            .foregroundColor(item.points > 0 ? .green : .red)
                    }
                    .padding(.vertical, 4)
                    
                    if item.id != historyItems.last?.id {
                        Divider()
                            .padding(.leading, 48)
                    }
                }
            }
        }
        .padding(16)
        .cardSurface(cornerRadius: 16)
    }

    private var relatedTransactions: [Transaction] {
        transactions.filter { transaction in
            if let program = summary.program {
                return transaction.card?.pointProgram?.id == program.id
            }
            return transaction.card?.pointProgram == nil
        }
    }

    private var relatedAdjustments: [PointAdjustment] {
        guard let program = summary.program else { return [] }
        return adjustments.filter { $0.pointProgram?.id == program.id }
    }

    private var historyItems: [PointHistoryItem] {
        var items: [PointHistoryItem] = []
        
        // 1. 手动/系统调整记录
        for adj in relatedAdjustments {
            items.append(PointHistoryItem(
                date: adj.date,
                points: adj.points,
                title: adj.type.displayName,
                subtitle: adj.note.isEmpty ? nil : adj.note,
                iconSystemName: adj.type.iconName,
                iconColor: accentColor
            ))
        }
        
        // 2. 交易返积分记录
        for tx in relatedTransactions where tx.pointsEarned > 0 {
            items.append(PointHistoryItem(
                date: tx.date,
                points: tx.pointsEarned,
                title: tx.merchant,
                subtitle: "消费获得",
                iconSystemName: "cart.fill",
                iconColor: .orange
            ))
        }
        
        return items.sorted(by: { $0.date > $1.date })
    }

    private var chartData: [MonthlyPointSnapshot] {
        let calendar = Calendar.current
        let now = Date()

        return (0..<6).compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else {
                return nil
            }
            let components = calendar.dateComponents([.year, .month], from: date)
            let transactionPoints = relatedTransactions.reduce(0) { partial, transaction in
                let tComponents = calendar.dateComponents([.year, .month], from: transaction.date)
                guard tComponents.year == components.year && tComponents.month == components.month else {
                    return partial
                }
                return partial + transaction.pointsEarned
            }
            let adjustmentPoints = relatedAdjustments.reduce(0) { partial, adjustment in
                let aComponents = calendar.dateComponents([.year, .month], from: adjustment.date)
                guard aComponents.year == components.year && aComponents.month == components.month else {
                    return partial
                }
                return partial + adjustment.points
            }
            let total = transactionPoints + adjustmentPoints
            let monthStart = calendar.date(from: components) ?? date
            return MonthlyPointSnapshot(date: monthStart, points: Double(total))
        }
        .reversed()
    }

    private var totalPoints: Int {
        summary.points
    }

    private var netPoints: Int {
        Int(chartData.reduce(0) { $0 + $1.points })
    }

    private var estimatedValue: Double {
        guard let program = summary.program, totalPoints > 0 else { return 0 }
        let value = Double(totalPoints) * program.pointValue
        return convertToMainCurrency(value, from: program.valueCurrencyCode.currencyCode)
    }

    private var isRatesReady: Bool {
        !exchangeRates.isEmpty
    }

    private func formattedPoints(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = AppLanguage.locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func formattedCurrency(_ value: Double, code: String) -> String {
        value.formatted(.currency(code: code).locale(AppLanguage.locale))
    }

    private func convertToMainCurrency(_ amount: Double, from currencyCode: String) -> Double {
        guard currencyCode != mainCurrencyCode else { return amount }
        guard let rate = rateForCurrency(currencyCode), rate > 0 else { return amount }
        return amount / rate
    }

    private func rateForCurrency(_ code: String) -> Double? {
        exchangeRates[code.lowercased()] ?? exchangeRates[code]
    }
}

private struct MonthlyPointSnapshot: Identifiable {
    let id = UUID()
    let date: Date
    let points: Double
}

private struct PointHistoryItem: Identifiable {
    let id = UUID()
    let date: Date
    let points: Int
    let title: String
    let subtitle: String?
    let iconSystemName: String
    let iconColor: Color
}
private struct PointAdjustmentEntryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\Point.bankName, order: .forward)])
    private var points: [Point]

    @State private var selectedPointID: UUID?
    @State private var pointsText: String = ""
    @State private var date: Date = Date()
    @State private var adjustmentType: AdjustmentType = .bonus
    @State private var note: String = ""

    // 添加积分时可用的类型
    private let addTypes: [AdjustmentType] = [.bonus, .earn, .transfer, .manual]

    var body: some View {
        NavigationView {
            Group {
                if points.isEmpty {
                    ContentUnavailableView(
                        "暂无积分计划",
                        systemImage: "star.circle",
                        description: Text("请先在积分库添加积分计划")
                    )
                } else {
                    Form {
                        Section(header: Text("积分计划")) {
                            Picker("积分计划", selection: $selectedPointID) {
                                ForEach(points) { point in
                                    Text(point.displayName)
                                        .tag(Optional(point.id))
                                }
                            }
                        }

                        Section(header: Text("积分数量")) {
                            HStack {
                                Text("积分")
                                Spacer()
                                TextField("0", text: $pointsText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                            }
                        }

                        Section(header: Text("类型")) {
                            Picker("调整类型", selection: $adjustmentType) {
                                ForEach(addTypes, id: \.self) { type in
                                    Label(type.displayName, systemImage: type.iconName)
                                        .tag(type)
                                }
                            }
                        }

                        Section(header: Text("日期")) {
                            DatePicker("入账日期", selection: $date, in: ...Date(), displayedComponents: .date)
                        }

                        Section(header: Text("备注（可选）")) {
                            TextField("例如：开卡奖励 50000 分", text: $note, axis: .vertical)
                                .lineLimit(2...4)
                        }
                    }
                }
            }
            .navigationTitle("手动添加积分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear {
            if selectedPointID == nil {
                selectedPointID = points.first?.id
            }
        }
        .onChange(of: points) { _, newPoints in
            if selectedPointID == nil {
                selectedPointID = newPoints.first?.id
            }
        }
    }

    private var selectedPoint: Point? {
        points.first { $0.id == selectedPointID } ?? points.first
    }

    private var pointsValue: Int? {
        let trimmed = pointsText.replacingOccurrences(of: ",", with: "")
        return Int(trimmed)
    }

    private var canSave: Bool {
        guard selectedPoint != nil, let value = pointsValue else { return false }
        return value > 0
    }

    private func save() {
        guard let point = selectedPoint, let value = pointsValue, value > 0 else { return }
        let adjustment = PointAdjustment(pointProgram: point, points: value, date: date, type: adjustmentType, note: note)
        context.insert(adjustment)
        dismiss()
    }
}

private struct PointRemovalEntryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Point.bankName, order: .forward)])
    private var points: [Point]

    @State private var selectedPointID: UUID?
    @State private var pointsText: String = ""
    @State private var date: Date = Date()
    @State private var adjustmentType: AdjustmentType = .redeem
    @State private var note: String = ""

    // 移除积分时可用的类型
    private let removeTypes: [AdjustmentType] = [.redeem, .expire, .transfer, .manual]

    var body: some View {
        NavigationView {
            Group {
                if points.isEmpty {
                    ContentUnavailableView(
                        "暂无积分计划",
                        systemImage: "star.circle",
                        description: Text("请先在积分库添加积分计划")
                    )
                } else {
                    Form {
                        Section(header: Text("积分计划")) {
                            Picker("积分计划", selection: $selectedPointID) {
                                ForEach(points) { point in
                                    Text(point.displayName)
                                        .tag(Optional(point.id))
                                }
                            }
                        }

                        Section(header: Text("移除积分数量")) {
                            HStack {
                                Text("积分")
                                Spacer()
                                TextField("0", text: $pointsText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                            }
                        }

                        Section(header: Text("类型")) {
                            Picker("调整类型", selection: $adjustmentType) {
                                ForEach(removeTypes, id: \.self) { type in
                                    Label(type.displayName, systemImage: type.iconName)
                                        .tag(type)
                                }
                            }
                        }

                        Section(header: Text("日期")) {
                            DatePicker("入账日期", selection: $date, in: ...Date(), displayedComponents: .date)
                        }

                        Section(header: Text("备注（可选）")) {
                            TextField("例如：兑换机票", text: $note, axis: .vertical)
                                .lineLimit(2...4)
                        }
                    }
                }
            }
            .navigationTitle("手动移除积分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear {
            if selectedPointID == nil {
                selectedPointID = points.first?.id
            }
        }
        .onChange(of: points) { _, newPoints in
            if selectedPointID == nil {
                selectedPointID = newPoints.first?.id
            }
        }
    }

    private var selectedPoint: Point? {
        points.first { $0.id == selectedPointID } ?? points.first
    }

    private var pointsValue: Int? {
        let trimmed = pointsText.replacingOccurrences(of: ",", with: "")
        return Int(trimmed)
    }

    private var canSave: Bool {
        guard selectedPoint != nil, let value = pointsValue else { return false }
        return value > 0
    }

    private func save() {
        guard let point = selectedPoint, let value = pointsValue, value > 0 else { return }
        let adjustment = PointAdjustment(pointProgram: point, points: -value, date: date, type: adjustmentType, note: note)
        context.insert(adjustment)
        dismiss()
    }
}

// MARK: - Previews

#if DEBUG
#Preview("积分总览") {
    PointSystemView()
        .previewEnvironment()
}

#Preview("积分总览 · 空") {
    PointSystemView()
        .previewEmptyEnvironment()
}

#Preview("积分明细") {
    NavigationStack {
        PointDetailView(summary: PreviewData.pointSummary,
                        transactions: PreviewData.transactions,
                        adjustments: PreviewData.adjustments,
                        exchangeRates: PreviewData.exchangeRates,
                        mainCurrencyCode: "CNY")
    }
    .previewEnvironment()
}

#Preview("积分汇总卡", traits: .sizeThatFitsLayout) {
    VStack(spacing: 14) {
        PointSummaryCard(summary: PreviewData.pointSummary, pointsText: "128,450")
        // 未归属积分：program 为 nil、没有主题色，走灰色兜底
        PointSummaryCard(
            summary: PointProgramSummary(id: "unassigned", program: nil,
                                         bankName: "未分类", pointName: "",
                                         points: 1_280, themeColors: []),
            pointsText: "1,280"
        )
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
    .previewEnvironment()
}

#Preview("积分 Logo 占位", traits: .sizeThatFitsLayout) {
    HStack(spacing: 16) {
        PointLogoPlaceholder(bankName: "HSBC HK", colors: [Color(hex: "C8102E"), Color(hex: "7A0A1C")])
        PointLogoPlaceholder(bankName: "Chase", colors: [.blue, .indigo])
        // 没有主题色时的灰色兜底
        PointLogoPlaceholder(bankName: "未分类", colors: [])
    }
    .padding()
}

#Preview("手动添加积分") {
    PointAdjustmentEntryView()
        .previewEnvironment()
}

#Preview("手动添加积分 · 无积分计划") {
    PointAdjustmentEntryView()
        .previewEmptyEnvironment()
}

#Preview("手动移除积分") {
    PointRemovalEntryView()
        .previewEnvironment()
}

#Preview("卡面容器修饰器", traits: .sizeThatFitsLayout) {
    VStack(spacing: 16) {
        Text("无 tint")
            .frame(maxWidth: .infinity)
            .padding(20)
            .modifier(CardSurface(cornerRadius: 16, tint: nil))
        Text("带 tint")
            .frame(maxWidth: .infinity)
            .padding(20)
            .modifier(CardSurface(cornerRadius: 16, tint: .orange))
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
#endif
