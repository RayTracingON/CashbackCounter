//
//  AppleIntelligenceService.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//
import FoundationModels
import Observation // 苹果的新状态管理框架
import Foundation


@MainActor
@Observable
final class ReceiptParser {
    
    // 1. 这里的 session 定义和苹果一模一样
    // ⚡️ 指令刻意保持精简：端侧模型 prefill 速度有限，指令 token 数直接决定响应延迟
    private let instructions = Instructions{
        "You are an expert receipt data extractor. Extract exact values from the OCR text into the structure."
        "The text is aligned row by row; items on the same row are related."
        "MERCHANT: usually near the top; may be Chinese, Japanese, or English."
        "AMOUNT: extract the FINAL PAID amount. Keywords: 实付/已支付/合计/合計/お支払い/請求金額/税込/Total/Grand Total/Amount Due."
        "- If there are discounts (立减/优惠/Discount), use the amount AFTER discount, NOT the subtotal (原价/小计). NEVER sum or add numbers yourself."
        "- JPY has no decimals: a dot inside a JPY number is a thousands separator ('74.405' -> 74405, '1.100' -> 1100)."
        "CATEGORY (from merchant and items): dining=restaurants/cafes/izakaya(居酒屋)/ramen; grocery=supermarkets/7-Eleven/Lawson/FamilyMart; travel=Uber/taxi/flights/hotels/Suica/Shinkansen; digital=electronics/Apple Store/Yodobashi/Bic Camera; anime=anime/manga/game goods(Animate/Melonbooks); streaming=Spotify/Netflix/Disney+/subscriptions; other=anything else."
        "Infer currency from symbols (¥, $, JPY) or location (e.g. Tokyo -> JPY)."
        "If a value is missing, leave it nil."
    }

    // ⚡️ 精简版；"Today is..." 已移到 parseScreenshot 的 prompt 里按调用时刻生成，
    // 避免长驻单例（OCRService.aiParser）持有过期日期
    private let screenshotInstructions = Instructions{
        "You are an expert receipt data extractor for payment screen captures. Extract exact values from the OCR text into the structure."
        "The text is aligned row by row; items on the same row are related."
        "MERCHANT: may be Chinese, Japanese, or English."
        "AMOUNT: use the FIRST amount shown on the screen — it is the total billing amount."
        "- IGNORE discounts (立减/优惠/碰一下立减/Discount) below it and any total-without-discount. DO NOT subtract discounts."
        "- JPY has no decimals: a dot inside a JPY number is a thousands separator ('74.405' -> 74405, '1.100' -> 1100)."
        "CATEGORY (from merchant and items): dining=restaurants/cafes/izakaya(居酒屋)/ramen; grocery=supermarkets/7-Eleven/Lawson/FamilyMart; travel=Uber/taxi/flights/hotels/Suica/Shinkansen; digital=electronics/Apple Store/Yodobashi/Bic Camera; anime=anime/manga/game goods(Animate/Melonbooks); streaming=Spotify/Netflix/Disney+/subscriptions; other=anything else."
        "Infer currency from symbols (¥, $, JPY) or location (e.g. Tokyo -> JPY)."
        "If a value is missing, leave it nil."
    }

    // ⚡️ 精简版：短信文本很短，指令是 prefill 的大头
    private let SMSinstructions = Instructions{
        "You are an expert transaction extractor for bank SMS notifications. Extract exact values into the structure."
        "MERCHANT: may be Chinese, Japanese, or English."
        "AMOUNT: the FINAL PAID amount (实付金额/合计/Total)."
        "- JPY has no decimals: a dot inside a JPY number is a thousands separator ('1.100' -> 1100)."
        "CATEGORY (from merchant): dining=restaurants/cafes/izakaya(居酒屋)/ramen; grocery=supermarkets/7-Eleven/Lawson/FamilyMart; travel=Uber/taxi/flights/hotels/Suica/Shinkansen; digital=electronics/Apple Store/Yodobashi/Bic Camera; anime=anime/manga/game goods(Animate/Melonbooks); streaming=Spotify/Netflix/Disney+/subscriptions; other=anything else."
        "If you are not sure about a value, leave it nil."
    }

    private let statementCardInstructions = Instructions{
        "You are an expert credit card statement parser."
        "Extract the card product name and the trailing digits of the card number."
        "Return ALL trailing digits exactly as shown after the mask (e.g. if '****71006', return '71006' not '7100')."
        "Do not truncate or pad the digits."
        "If a field is missing, return nil for it."
        "Do not guess. Use only information present in the statement text."
    }

    private let statementTransactionInstructions = Instructions{
        "You are an expert transaction classifier."
        "Infer transaction region, payment method, and category from the provided transaction summary."
        "Use merchant name, currency code/symbols, and context words to infer region."
        "CRITICAL RULES FOR CATEGORIZATION:"
        "- Analyze the merchant name and items purchased."
        "- 'dining': Restaurants, Cafes, Starbucks, Izakaya (居酒屋), Ramen (ラーメン)."
        "- 'grocery': Supermarkets, 7-Eleven, Lawson, FamilyMart, Daily necessities."
        "- 'travel': Uber, Taxi, Flights, Hotels, Suica, Pasmo, Shinkansen (新幹線)."
        "- 'digital': Electronics, Apple Store, Yodobashi, Bic Camera."
        "- 'anime': Anime, manga, game goods (Animate, Melonbooks, Comiket)."
        "- 'streaming': Spotify, Netflix, Disney+, Apple TV+, subscriptions."
        "- 'other': Anything that doesn't fit above."
        "Use payment hints such as Apple Pay, online, QR, tap, NFC, or card present/online words."
        "CRITICAL RULES FOR foreignAmount:"
        "- foreignAmount is ONLY for currency conversion. It means the original amount in the foreign currency BEFORE conversion."
        "- A conversion looks like: '775.00 X 0.00642580' or 'USD 100.00 → HKD 780.00'. The foreign side is foreignAmount."
        "- If BillingCurrency matches the transaction currency, there is NO foreign amount. Return nil."
        "- If there is only one amount shown and no conversion/exchange details, return nil."
        "- NEVER copy the billing amount into foreignAmount. If unsure, return nil."
        "If unsure about any field, return nil."
    }

    private let statementRowInstructions = Instructions{
        "You are an expert credit card statement transaction extractor."
        "You will be given a single transaction block from OCR."
        "Extract at most one transaction from this block."
        "Only return merchant with alphabet characters or necessary numbers."
        "Ignore blocks that are not transactions (headers, balances, payments, totals, interest, fees)."
        "For the transaction return: transactionDate, merchant, billingAmount, foreignAmount, foreignCurrency."
        "Dates must be in YYYY-MM-DD. If only one date is present, use it for both transactionDate."
        "billingAmount is the settled amount in statement currency."
        "Using the foreignCurrency to confirm foreign amount and billing amount"
        "Do not guess. If unsure, return nil for the field."
    }

    private let statementTransactionsBulkInstructions = Instructions{
        "Extract transactions from the markdown table."
        "Skip headers, balances, payments, totals, interest, fees."
        "Dates: YYYY-MM-DD. billingAmount = settled amount."
        "foreignAmount: only if currency conversion shown, else nil."
        "If unsure, return nil."
    }
    
    init() {}

    // 预热用 session：持有引用避免 prewarm 后立即释放
    private var warmupSession: LanguageModelSession?

    // MARK: - 模型选择（本地 / 云端 Private Cloud Compute）

    /// SettingsView 中"云端模型"开关使用同一个 key
    nonisolated static let cloudModelDefaultsKey = "useCloudAIModel"

    nonisolated private static var isCloudModelEnabled: Bool {
        UserDefaults.standard.bool(forKey: cloudModelDefaultsKey)
    }

    /// 按用户设置创建 session：开启云端且 PCC 可用时走云端，否则回退本地模型。
    /// 云端需要 iOS 27+ 及 com.apple.developer.private-cloud-compute 受管权限。
    private func makeSession(instructions: Instructions) -> LanguageModelSession {
        if #available(iOS 27.0, *), Self.isCloudModelEnabled {
            let cloudModel = PrivateCloudComputeLanguageModel()
            if cloudModel.isAvailable {
                print("☁️ 使用云端模型 (Private Cloud Compute)")
                return LanguageModelSession(model: cloudModel, instructions: instructions)
            }
            print("⚠️ 云端模型不可用（未授权/无网络/系统未就绪），回退本地模型")
        }
        return LanguageModelSession(instructions: instructions)
    }

    /// 检查 Apple Intelligence 是否可用；不可用时抛出带用户可读原因的错误。
    /// 所有 parse 方法调用模型前统一走这里，避免在不支持的设备上静默失败。
    nonisolated static func ensureModelAvailable() throws {
        // 云端模式且 PCC 可用时直接放行（makeSession 会选择云端模型）；
        // 否则继续检查本地模型作为兜底路径
        if #available(iOS 27.0, *), isCloudModelEnabled,
           PrivateCloudComputeLanguageModel().isAvailable {
            return
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            let message: String
            switch reason {
            case .deviceNotEligible:
                message = String(localized: "此设备不支持 Apple Intelligence")
            case .appleIntelligenceNotEnabled:
                message = String(localized: "请在系统设置中开启 Apple Intelligence")
            case .modelNotReady:
                message = String(localized: "Apple Intelligence 模型尚未就绪，请稍后再试")
            @unknown default:
                message = String(localized: "Apple Intelligence 暂不可用")
            }
            throw NSError(
                domain: "ReceiptParser",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    /// 预热模型：在 OCR 进行的同时把模型权重加载进内存，缩短首次 respond 的延迟。
    /// 云端模式下无本地权重可加载，直接跳过。
    func prewarm() {
        if #available(iOS 27.0, *), Self.isCloudModelEnabled,
           PrivateCloudComputeLanguageModel().isAvailable {
            return
        }
        guard case .available = SystemLanguageModel.default.availability else { return }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        warmupSession = session
    }

    /// Extract the last 4 digits from a card number string.
    /// Exposed as internal static for testability.
    nonisolated static func normalizedCardLast4(_ value: String?) -> String? {
        let digits = value?.filter { $0.isNumber } ?? ""
        guard digits.count >= 4 else { return nil }
        return String(digits.suffix(4))
    }
    
    // 3. 解析方法
    func parse(text: String) async throws -> ReceiptMetadata {
            try Self.ensureModelAvailable()

            // 👇👇👇 核心修改：每次调用 parse 时，创建一个全新的 session！
            // 这样每次都是“第一次”，没有历史包袱
            let session = makeSession(instructions: instructions)
            
            let response = try await session.respond(
                generating: ReceiptMetadata.self,
                options: GenerationOptions(sampling: .greedy) // 抽取任务用贪心采样：结果稳定，无随机性
            ) {
                "Please analyze the following receipt text carefully. It may contain non-English characters such as Chinese or Japanese, but you must process it as part of this English prompt:"
                "=== START OF RECEIPT DATA ==="
                text
                "=== END OF RECEIPT DATA ==="
            }

        let metadata = response.content
        let amountText = metadata.totalAmount.map { String(format: "%.2f", $0) } ?? "nil"
        print("OCR fields: merchant=\(metadata.merchant ?? "nil"), amount=\(amountText), currency=\(metadata.currency ?? "nil"), date=\(metadata.dateString ?? "nil"), cardLast4=\(metadata.cardLast4 ?? "nil"), category=\(metadata.category?.rawValue ?? "nil")")
        return metadata
    }

    func parseScreenshot(text: String) async throws -> ReceiptMetadata {
        try Self.ensureModelAvailable()
        let session = makeSession(instructions: screenshotInstructions)
        let today = Date().formatted(date: .abbreviated, time: .omitted)

        let response = try await session.respond(
            generating: ReceiptMetadata.self,
            options: GenerationOptions(sampling: .greedy)
        ) {
            "Today is \(today). If no date is found in the text, use today."
            "Please analyze the following screenshot text carefully. It may contain non-English characters such as Chinese or Japanese, but you must process it as part of this English prompt:"
            "=== START OF SCREENSHOT DATA ==="
            text
            "=== END OF SCREENSHOT DATA ==="
        }

        let metadata = response.content
        let amountText = metadata.totalAmount.map { String(format: "%.2f", $0) } ?? "nil"
        print("Screenshot OCR fields: merchant=\(metadata.merchant ?? "nil"), amount=\(amountText), currency=\(metadata.currency ?? "nil"), date=\(metadata.dateString ?? "nil"), cardLast4=\(metadata.cardLast4 ?? "nil"), category=\(metadata.category?.rawValue ?? "nil")")
        return metadata
    }

    func SMSparse(text: String) async throws -> ReceiptMetadata {
            try Self.ensureModelAvailable()

            // 👇👇👇 核心修改：每次调用 parse 时，创建一个全新的 session！
            // 这样每次都是“第一次”，没有历史包袱
            let session = makeSession(instructions: SMSinstructions)
            
            let response = try await session.respond(
                generating: ReceiptMetadata.self,
                options: GenerationOptions(sampling: .greedy)
            ) {
                "Please analyze the following SMS text carefully. It may contain non-English characters such as Chinese or Japanese, but you must process it as part of this English prompt:"
                "=== START OF SMS DATA ==="
                text
                "=== END OF SMS DATA ==="
            }

        let metadata = response.content
        let amountText = metadata.totalAmount.map { String(format: "%.2f", $0) } ?? "nil"
        print("SMS OCR fields: merchant=\(metadata.merchant ?? "nil"), amount=\(amountText), cardLast4=\(metadata.cardLast4 ?? "nil"), category=\(metadata.category?.rawValue ?? "nil")")
        return metadata
        }

    func parseStatementCard(text: String) async throws -> StatementCardMetadata {
        try Self.ensureModelAvailable()
        let session = makeSession(instructions: statementCardInstructions)
        let response = try await session.respond(
            generating: StatementCardMetadata.self
        ) {
            "Analyze this statement text:"
            text
        }

        var metadata = response.content
        metadata.cardLast4 = Self.normalizedCardLast4(metadata.cardLast4)
        print("Statement OCR fields: cardLast4=\(metadata.cardLast4 ?? "nil"), cardName=\(metadata.cardName ?? "nil")")
        return metadata
    }

    func parseStatementTransaction(text: String) async throws -> StatementTransactionMetadata {
        try Self.ensureModelAvailable()
        let session = makeSession(instructions: statementTransactionInstructions)
        let response = try await session.respond(
            generating: StatementTransactionMetadata.self
        ) {
            "Analyze this transaction summary:"
            text
        }

        let metadata = response.content
        print("TEXT",text)
        let foreignAmountText = metadata.foreignAmount.map { String(format: "%.2f", $0) } ?? "nil"
        print("Statement OCR fields: foreignAmount=\(foreignAmountText), payment=\(metadata.paymentMethod?.rawValue ?? "nil"), category=\(metadata.category?.rawValue ?? "nil")")
        return metadata
    }
    
    func parseStatementTransactionBlock(text: String) async throws -> StatementRowTransaction {
        try Self.ensureModelAvailable()
        let session = makeSession(instructions: statementRowInstructions)
        let response = try await session.respond(
            generating: StatementRowTransaction.self
        ) {
            "Analyze this statement block:"
            text
        }

        return response.content
    }

    func parseStatementTransactionsBatch(text: String) async throws -> StatementRowTransactionList {
        try Self.ensureModelAvailable()
        let session = makeSession(instructions: statementTransactionsBulkInstructions)
        let response = try await session.respond(
            generating: StatementRowTransactionList.self
        ) {
            "Analyze these statement tables:"
            text
        }

        return response.content
    }

}

