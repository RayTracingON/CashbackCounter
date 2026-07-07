//
//  AddTransactionFromScreenshotIntent.swift
//  CashbackCounter
//
//  通过快捷指令传入截屏图片，OCR 识别后自动创建交易
//

import AppIntents
import SwiftUI
import UIKit
import SwiftData
import UniformTypeIdentifiers

/// 通过屏幕截图添加交易的意图（配合操作按钮 + 快捷指令使用）
struct AddTransactionFromScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "从屏幕截图添加交易"
    static var description = IntentDescription("截取屏幕内容，OCR 识别后自动记账")

    // 参数：快捷指令传入的截图文件
    @Parameter(
        title: "屏幕截图",
        description: "快捷指令截取的屏幕截图",
        supportedContentTypes: [.image]
    )
    var screenshot: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("识别截图 \(\.$screenshot) 并记账")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        print("[AddTransactionFromScreenshotIntent] 🏁 快捷指令开始执行")
        do {
            // 与主 App 共用同一个容器和 mainContext：
            // 避免另起 CloudKit 同步栈（后台拉起时会报 BGTaskScheduler notPermitted），
            // 且写入后主界面 @Query 能立即刷新
            let modelContext = SharedModelContainer.shared.mainContext

            // 1. IntentFile → UIImage
            let imageData = screenshot.data
            guard let image = UIImage(data: imageData) else {
                print("[AddTransactionFromScreenshotIntent] ❌ 无法读取截图数据")
                throw NSError(
                domain: "AddTransactionFromScreenshotIntent",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "无法读取截图数据"]
            )
        }

            // 2. OCR 文字提取（Vision）
            // 先预热 AI 模型：权重加载与 OCR 并行，省掉后面 AI 调用的冷启动
            let parser = ReceiptParser()
            parser.prewarm()
            print("[AddTransactionFromScreenshotIntent] 🔍 开始 OCR 文字提取")
            let broadLanguages = ["zh-Hans", "en-US", "ja-JP", "zh-Hant"]
            let rawText = await OCRService.recognizeTextInRows(from: image, languages: broadLanguages)
            print("[AddTransactionFromScreenshotIntent] 🔍 OCR 结果:\n\(rawText)")

            guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("[AddTransactionFromScreenshotIntent] ❌ 截图中未识别到文字内容")
                throw NSError(
                domain: "AddTransactionFromScreenshotIntent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "截图中未识别到文字内容"]
            )
        }

            // 3. AI 解析（独立 ReceiptParser，使用 try await 暴露错误）
            print("[AddTransactionFromScreenshotIntent] 🤖 开始 AI 解析")
            let metadata = try await parser.parseScreenshot(text: rawText)
            print("[AddTransactionFromScreenshotIntent] 🤖 AI 解析完成: \(metadata)")

            // 4. 核心字段检查
            guard let merchant = metadata.merchant,
                  let amount = metadata.totalAmount else {
                print("[AddTransactionFromScreenshotIntent] ❌ 未能从截图中识别出商户名或金额")
                throw NSError(
                domain: "AddTransactionFromScreenshotIntent",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "未能从截图中识别出商户名或金额"]
            )
        }

        let category = metadata.category ?? .other

        // 使用 OCR 解析出的日期，解析失败则回退到当前日期
        let date: Date = {
            guard let dateStr = metadata.dateString else { return Date() }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.date(from: dateStr) ?? Date()
        }()

            // 5. 使用本地推断获取 Region，若失败则根据 currency 推断
            let region: Region
            if let inferredRegion = OCRService.simpleInferRegion(from: rawText) {
                region = inferredRegion
                print("[AddTransactionFromScreenshotIntent] 🌍 本地推断地区成功: \(region.rawValue)")
            } else {
                switch metadata.currency {
                case let code where code?.contains("CNY") == true: region = .cn
                case let code where code?.contains("USD") == true: region = .us
                case let code where code?.contains("HKD") == true: region = .hk
                case let code where code?.contains("JPY") == true: region = .jp
                case let code where code?.contains("NZD") == true: region = .nz
                case let code where code?.contains("TWD") == true: region = .tw
                case let code where code?.contains("GBP") == true: region = .uk
                case let code where code?.contains("MOP") == true: region = .mo
                default:                                            region = .cn
                }
                print("[AddTransactionFromScreenshotIntent] 🌍 AI 推断地区: \(region.rawValue)")
            }

            // 6. 尝试匹配信用卡
        let availableCards = try modelContext.fetch(FetchDescriptor<CreditCard>())
        let selectedCard: CreditCard? = {
            if let last4 = metadata.cardLast4 {
                if let matched = availableCards.first(where: { $0.endNum == last4 }) {
                    return matched
                }
            }
            
            // 尝试使用默认卡片
            let defaultCardID = UserDefaults.standard.string(forKey: "defaultCardID") ?? ""
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

        // 7. 计算入账金额和返现
        // TODO: billingAmount 未做换汇，异币种消费的原始金额会直接进入以卡币种计价的上限统计
        let billingAmount = amount
        var cashback: Double = 0.0
        var pointsEarned: Int = 0

        if let card = selectedCard {
            if card.rewardType == .points {
                let pointValue = await resolvePointValueInCardCurrency(
                    pointProgram: card.pointProgram,
                    cardCurrency: card.issueRegion.currencyCode
                )
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
                    paymentMethod: .online
                )
            }
        }

            // 8. 请求用户确认
            let currencySymbol = region.currencySymbol
            let cardName = selectedCard != nil ? "\(selectedCard!.bankName)尾号\(selectedCard!.endNum)" : "默认分类"
            let confirmDialog = IntentDialog("识别出：\(merchant) \(currencySymbol)\(String(format: "%.2f", amount))\n将记入 \(cardName)，是否确认？")
            print("[AddTransactionFromScreenshotIntent] 💬 请求用户确认...")
            try await requestConfirmation(result: .result(dialog: confirmDialog))
            print("[AddTransactionFromScreenshotIntent] 💬 用户已确认")

            // 9. 创建并保存交易（附带截图作为收据）
            print("[AddTransactionFromScreenshotIntent] 💾 正在保存交易...")
            let receiptData = image.jpegData(compressionQuality: 0.5)
            let newTransaction = Transaction(
                merchant: merchant,
                category: category,
                location: region,
                amount: amount,
                date: date,
                card: selectedCard,
                receiptData: receiptData,
                billingAmount: billingAmount,
                cashbackAmount: cashback,
                pointsEarned: pointsEarned,
                paymentMethod: .online,
                // billingAmount 即原币金额，入账币种如实记为消费地币种
                billingCurrencyCode: region.currencyCode
            )
            modelContext.insert(newTransaction)
            try modelContext.save()

            // 10. 返回结果
            print("[AddTransactionFromScreenshotIntent] ✅ 快捷指令执行成功！")
            return .result(dialog: "✅ 已添加：\(merchant) – \(currencySymbol)\(String(format: "%.2f", amount))")
        } catch {
            print("[AddTransactionFromScreenshotIntent] ❌ 捕获到错误: \(error.localizedDescription)")
            print("[AddTransactionFromScreenshotIntent] ❌ 详细错误: \(error)")
            throw error
        }
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
