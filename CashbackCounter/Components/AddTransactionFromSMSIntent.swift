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

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {

        // 与主 App 共用同一个容器和 mainContext，避免另起 CloudKit 同步栈
        let modelContext = SharedModelContainer.shared.mainContext
        
        
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
              let detectedRegion = metadata.currency,
              let category = metadata.category else {
            throw NSError(domain: "AddTransactionFromSMSIntent", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少商户、金额或类别信息"])
        }

        // 将日期字符串转换为 Date，不存在则默认今天
        let date: Date = {
            guard let dateStr = metadata.dateString else { return Date() }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.date(from: dateStr) ?? Date()
        }()

        // 使用本地推断获取 Region，若失败则根据 currency 推断
        let region: Region
        if let inferredRegion = OCRService.simpleInferRegion(from: textToParse) {
            region = inferredRegion
        } else {
            switch metadata.currency {
            case let code where code?.contains("CNY") == true: region = .cn
            case let code where code?.contains("USD") == true: region = .us
            case let code where code?.contains("HKD") == true: region = .hk
            case let code where code?.contains("JPY") == true: region = .jp
            case let code where code?.contains("NZD") == true: region = .nz
            case let code where code?.contains("TWD") == true: region = .tw
            case let code where code?.contains("GBP") == true: region = .uk
            default:                                          region = .other
            }
        }

        let availableCards = try modelContext.fetch(FetchDescriptor<CreditCard>())
        @AppStorage("defaultCardID") var defaultCardID: String = ""
        
        let selectedCard: CreditCard? = {
            if let last4 = metadata.cardLast4 {
                if let matched = availableCards.first(where: { $0.endNum == last4 }) {
                    return matched
                }
            }
            
            // 尝试使用默认卡片
            if !defaultCardID.isEmpty {
                let parts = defaultCardID.split(separator: "|")
                if parts.count == 2 {
                    let bank = String(parts[0])
                    let end = String(parts[1])
                    return availableCards.first { $0.bankName == bank && $0.endNum == end }
                }
            }
            return nil
        }()

        // 计算入账金额和返现
        let billingAmount = amount    // 如需跨币种，可根据汇率再计算
        var cashback: Double = 0.0
        var pointsEarned: Int = 0
        if let card = selectedCard {
            if card.rewardType == .points {
                let pointValue = await resolvePointValueInCardCurrency(pointProgram: card.pointProgram, cardCurrency: card.issueRegion.currencyCode)
                let result = card.calculateCappedPoints(
                    amount: billingAmount,
                    category: category,
                    location: region,
                    date: date,
                    paymentMethod: .offline,
                    pointValueInCardCurrency: pointValue
                )
                cashback = result.value
                pointsEarned = result.points
            } else {
                cashback = card.calculateCappedCashback(
                    amount: billingAmount,
                    category: category,
                    location: region,
                    date: date,
                    paymentMethod: .offline
                )
            }
        }

        // 创建并保存交易
        let newTransaction = Transaction(
            merchant: merchant,
            category: category,
            location: region,
            amount: amount,
            date: date,
            card: selectedCard,
            receiptData: nil,
            billingAmount: billingAmount,
            cashbackAmount: cashback,
            pointsEarned: pointsEarned
        )
        modelContext.insert(newTransaction)
        try modelContext.save()
        // 返回意图执行结果，系统会在快捷指令中显示“完成”
        return .result(dialog: "已成功添加账单：\(merchant) – ¥\(amount)")
    }

    private func resolvePointValueInCardCurrency(pointProgram: Point?, cardCurrency: String) async -> Double {
        guard let pointProgram else { return 0 }
        let pointRegion = pointProgram.valueCurrencyCode
        if pointRegion.currencyCode == cardCurrency {
            return pointProgram.pointValue
        }
        let rates = await CurrencyService.getRates(base: pointRegion.currencyCode)
        if let rate = rates[cardCurrency], rate > 0 {
            return pointProgram.pointValue * rate
        }
        return pointProgram.pointValue
    }
}
