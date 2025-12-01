import AppIntents
import SwiftUI
import UIKit
import SwiftData
import UniformTypeIdentifiers
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

    private static let sharedModelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: Transaction.self, CreditCard.self)
        } catch {
            fatalError("Failed to create shared model container: \(error)")
        }
    }()

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        
        let modelContext = ModelContext(Self.sharedModelContainer)
        
        
        let textToParse = smsText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !textToParse.isEmpty else {
                    throw NSError(domain: "AddTransactionFromSMSIntent", code: 0, userInfo: [NSLocalizedDescriptionKey: "请提供短信文本"])
                }
        // 在主线程上创建解析器并调用 parse()
        let parser = ReceiptParser()
        let metadata = try await parser.SMSparse(text: textToParse)

        // 核心字段检查
        guard let merchant = metadata.merchant,
              let amount = metadata.totalAmount,
              let detectedRegion = OCRService.simpleInferRegion(from: textToParse),
              let category = metadata.category else {
            throw NSError(domain: "AddTransactionFromSMSIntent", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少商户、金额或类别信息"])
        }

        // 将日期字符串转换为 Date，不存在则默认今天
        let date = Date()

        // 根据 currency 推断 Region
        let region: Region
        switch metadata.currency {
        case let code where code?.contains("CNY") == true: region = .cn
        case let code where code?.contains("USD") == true: region = .us
        case let code where code?.contains("HKD") == true: region = .hk
        case let code where code?.contains("JPY") == true: region = .jp
        case let code where code?.contains("NZD") == true: region = .nz
        case let code where code?.contains("TWD") == true: region = .tw
        default:                                          region = .other
        }

        let availableCards = try modelContext.fetch(FetchDescriptor<CreditCard>())
        let selectedCard: CreditCard? = {
            if let last4 = metadata.cardLast4 {
                return availableCards.first { $0.endNum == last4 }
            }
            return nil
        }()

        // 计算入账金额和返现
        let billingAmount = amount    // 如需跨币种，可根据汇率再计算
        let cashback = selectedCard?.calculateCappedCashback(
            amount: billingAmount,
            category: category,
            location: region,
            date: date
        ) ?? 0.0

        // 创建并保存交易
        let newTransaction = Transaction(
            merchant: merchant,
            category: category,
            location: detectedRegion,
            amount: amount,
            date: date,
            card: selectedCard,
            receiptData: nil,
            billingAmount: billingAmount,
            cashbackAmount: cashback
        )
        modelContext.insert(newTransaction)
        try modelContext.save()
        // 返回意图执行结果，系统会在快捷指令中显示“完成”
        return .result(dialog: "已成功添加账单：\(merchant) – ¥\(amount)")
    }
}
