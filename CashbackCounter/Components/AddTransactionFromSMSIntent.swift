import AppIntents
import SwiftData
import Foundation

/// 通过短信文本添加交易的意图
struct AddTransactionFromSMSIntent: AppIntent {
    // 提供意图名称和描述，便于快捷指令显示
    static var title: LocalizedStringResource = "从信用卡通知短信添加交易"
    static var description = IntentDescription("解析短信内容并新增一笔消费记录")

    // 参数：用户在快捷指令里输入或粘贴的短信文本
    @Parameter(
      title: "短信全文",
      requestValueDialog: IntentDialog("请粘贴信用卡短信内容")  // 提示用户输入内容
    )
    var smsText: String

    static var parameterSummary: some ParameterSummary {
        Summary("解析短信文本 \(\.$smsText)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 与主 App 共用同一个容器和 mainContext，避免另起 CloudKit 同步栈
        let modelContext = SharedModelContainer.shared.mainContext

        let textToParse = smsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textToParse.isEmpty else {
            throw NSError(domain: "AddTransactionFromSMSIntent", code: 0, userInfo: [NSLocalizedDescriptionKey: "请提供短信文本"])
        }
        // 模型漏抽金额/币种时用规则兜底
        let parser = ReceiptParser()
        let parsed = try await parser.SMSparse(text: textToParse)
        let metadata = OCRService.backfill(parsed.metadata, rawText: textToParse)

        // 核心字段检查：短信记账没有确认弹窗，商户 / 金额 / 类别缺一个都不入账
        guard let merchant = metadata.merchant,
              let amount = metadata.totalAmount,
              let category = metadata.category else {
            throw NSError(domain: "AddTransactionFromSMSIntent", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少商户、金额或类别信息"])
        }
        // 识别出的日期解析失败时回退到今天
        let date = metadata.dateString?.toDate() ?? Date()

        // 匹配信用卡：先按识别出的尾号，再退回设置里的默认卡
        let availableCards = try modelContext.fetch(FetchDescriptor<CreditCard>())
        let selectedCard = metadata.cardLast4.flatMap { last4 in availableCards.first { $0.endNum == last4 } }
            ?? CreditCard.defaultCard(in: availableCards)

        // 金额与地区：拆成原币（消费地）和入账（卡币种）两组（见 RecognizedAmounts）。
        // 「消费HKD8.60，折合人民币7.33元」这类短信两边都是现成的数，云端模型会直接标出原币 / 入账；
        // 没写币种时多半就是发卡行本币，按所选卡的发卡地区兜底
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: amount,
            currency: metadata.currency,
            rawText: textToParse,
            card: selectedCard,
            conversion: parsed.conversion
        )

        // 计算返现：按入账金额（卡币种）+ 消费地区
        let paymentMethod: PaymentMethod = .offline
        let reward = await selectedCard?.cappedReward(
            amount: amounts.billingAmount,
            category: category,
            location: amounts.location,
            date: date,
            paymentMethod: paymentMethod
        ) ?? (value: 0, points: 0)

        // 创建并保存交易
        let newTransaction = Transaction(
            merchant: merchant,
            category: category,
            location: amounts.location,
            amount: amounts.amount,
            date: date,
            card: selectedCard,
            receiptData: nil,
            billingAmount: amounts.billingAmount,
            cashbackAmount: reward.value,
            pointsEarned: reward.points,
            paymentMethod: paymentMethod,
            billingCurrencyCode: amounts.billingRegion.currencyCode
        )
        modelContext.insert(newTransaction)
        try modelContext.save()
        // 与截图记账共用同一条已翻译的文案；显示原币金额
        return .result(dialog: "✅ 已添加：\(merchant) – \(amounts.location.currencySymbol)\(String(format: "%.2f", amounts.amount))")
    }
}
