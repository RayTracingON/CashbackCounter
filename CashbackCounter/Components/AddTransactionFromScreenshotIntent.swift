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
            guard let image = UIImage(data: screenshot.data) else {
                print("[AddTransactionFromScreenshotIntent] ❌ 无法读取截图数据")
                throw NSError(
                    domain: "AddTransactionFromScreenshotIntent",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "无法读取截图数据"]
                )
            }

            // 2+3. 解析：云端多模态就绪时原图直传，否则 OCR + 文本解析。
            // OCR 文本两条路都要：外币消费的截图常同屏显示入账金额和原币金额，要靠它找出另一种币种
            let parser = ReceiptParser()
            var multimodalResult: (metadata: ReceiptMetadata, conversion: CurrencyConversion?)? = nil
            let rawText: String

            if #available(iOS 27.0, *), ReceiptParser.isMultimodalAvailable {
                print("[AddTransactionFromScreenshotIntent] ☁️🖼️ 云端多模态解析截图（并行 OCR）")
                async let ocrText = OCRService.recognizeTextInRows(from: image)
                do {
                    multimodalResult = try await parser.parseScreenshotImage(image)
                } catch {
                    print("[AddTransactionFromScreenshotIntent] ❌ 多模态解析失败，回退 OCR 文本管线: \(error)")
                }
                rawText = await ocrText
            } else {
                // 先预热 AI 模型：权重加载与 OCR 并行，省掉后面 AI 调用的冷启动
                parser.prewarm()
                print("[AddTransactionFromScreenshotIntent] 🔍 开始 OCR 文字提取")
                rawText = await OCRService.recognizeTextInRows(from: image)
            }
            print("[AddTransactionFromScreenshotIntent] 🔍 OCR 结果:\n\(rawText)")

            // conversion：同屏两种币种时云端模型标出的原币 / 入账两侧（本地模型为 nil）
            let metadata: ReceiptMetadata
            let conversion: CurrencyConversion?
            if let multimodalResult {
                metadata = OCRService.backfill(multimodalResult.metadata, rawText: rawText)
                conversion = multimodalResult.conversion
            } else {
                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    print("[AddTransactionFromScreenshotIntent] ❌ 截图中未识别到文字内容")
                    throw NSError(
                        domain: "AddTransactionFromScreenshotIntent",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "截图中未识别到文字内容"]
                    )
                }

                // AI 解析；模型漏抽金额/币种时用规则兜底，避免整条快捷指令因一个 nil 字段失败
                print("[AddTransactionFromScreenshotIntent] 🤖 开始 AI 解析")
                let parsed = try await parser.parseScreenshot(text: rawText)
                metadata = OCRService.backfill(parsed.metadata, rawText: rawText)
                conversion = parsed.conversion
            }
            print("[AddTransactionFromScreenshotIntent] 🤖 AI 解析完成: \(metadata)")

            // 4. 核心字段检查：只有金额是硬性要求；
            // 商户名识别失败用占位符继续走确认弹窗，用户可在弹窗里取消
            guard let amount = metadata.totalAmount ?? conversion?.billing?.amount ?? conversion?.original?.amount else {
                print("[AddTransactionFromScreenshotIntent] ❌ 未能从截图中识别出金额")
                throw NSError(
                    domain: "AddTransactionFromScreenshotIntent",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "未能从截图中识别出金额"]
                )
            }
            let merchant = metadata.merchant ?? String.loc("未知商户")
            let category = metadata.category ?? .other
            // 识别出的日期解析失败时回退到今天
            let date = metadata.dateString?.toDate() ?? Date()

            // 5. 匹配信用卡：先按识别出的尾号，再退回设置里的默认卡。
            // 排在金额拆分之前：入账币种和兜底地区都要看卡
            let availableCards = try modelContext.fetch(FetchDescriptor<CreditCard>())
            let selectedCard = metadata.cardLast4.flatMap { last4 in availableCards.first { $0.endNum == last4 } }
                ?? CreditCard.defaultCard(in: availableCards)

            // 6. 金额与地区：拆成原币（消费地）和入账（卡币种）两组。
            // 同屏两种币种时优先用云端模型标出的两侧，没标再从 OCR 文本里找；
            // 只有一种币种且与卡币种不同时按汇率估算（见 RecognizedAmounts）
            let amounts = await RecognizedAmounts.resolve(
                totalAmount: amount,
                currency: metadata.currency,
                rawText: rawText,
                card: selectedCard,
                conversion: conversion
            )
            print("[AddTransactionFromScreenshotIntent] 🌍 \(amounts.location.rawValue) \(amounts.location.currencyCode) \(amounts.amount) → 入账 \(amounts.billingRegion.currencyCode) \(amounts.billingAmount)\(amounts.isBillingEstimated ? "（汇率估算）" : "")")

            // 7. 计算返现：按入账金额（卡币种）+ 消费地区。
            // 奖励计算与保存必须用同一个支付方式，否则日后编辑这笔交易时奖励会被重算成另一个数
            let paymentMethod: PaymentMethod = .online
            let reward = await selectedCard?.cappedReward(
                amount: amounts.billingAmount,
                category: category,
                location: amounts.location,
                date: date,
                paymentMethod: paymentMethod
            ) ?? (value: 0, points: 0)

            // 8. 请求用户确认：原币和入账币种不同时两个都显示，汇率估算的入账金额标 ≈
            let currencySymbol = amounts.location.currencySymbol
            let amountText = String(format: "%.2f", amounts.amount)
            let cardName = selectedCard.map { "\($0.bankName)尾号\($0.endNum)" } ?? "默认分类"
            let confirmDialog: IntentDialog
            if amounts.billingRegion != amounts.location {
                let billingSymbol = (amounts.isBillingEstimated ? "≈" : "") + amounts.billingRegion.currencySymbol
                let billingText = String(format: "%.2f", amounts.billingAmount)
                confirmDialog = IntentDialog("识别出：\(merchant) \(currencySymbol)\(amountText)（入账 \(billingSymbol)\(billingText)）\n将记入 \(cardName)，是否确认？")
            } else {
                confirmDialog = IntentDialog("识别出：\(merchant) \(currencySymbol)\(amountText)\n将记入 \(cardName)，是否确认？")
            }
            print("[AddTransactionFromScreenshotIntent] 💬 请求用户确认...")
            try await requestConfirmation(result: .result(dialog: confirmDialog))
            print("[AddTransactionFromScreenshotIntent] 💬 用户已确认")

            // 9. 创建并保存交易（附带截图作为收据）
            print("[AddTransactionFromScreenshotIntent] 💾 正在保存交易...")
            let newTransaction = Transaction(
                merchant: merchant,
                category: category,
                location: amounts.location,
                amount: amounts.amount,
                date: date,
                card: selectedCard,
                receiptData: image.jpegData(compressionQuality: AppConfig.receiptJPEGQuality),
                billingAmount: amounts.billingAmount,
                cashbackAmount: reward.value,
                pointsEarned: reward.points,
                paymentMethod: paymentMethod,
                billingCurrencyCode: amounts.billingRegion.currencyCode
            )
            modelContext.insert(newTransaction)
            try modelContext.save()

            // 10. 返回结果
            print("[AddTransactionFromScreenshotIntent] ✅ 快捷指令执行成功！")
            return .result(dialog: "✅ 已添加：\(merchant) – \(currencySymbol)\(amountText)")
        } catch {
            print("[AddTransactionFromScreenshotIntent] ❌ 捕获到错误: \(error.localizedDescription)")
            print("[AddTransactionFromScreenshotIntent] ❌ 详细错误: \(error)")
            throw error
        }
    }
}
