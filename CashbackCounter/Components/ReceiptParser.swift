//
//  AppleIntelligenceService.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//
import FoundationModels
import ClaudeForFoundationModels
import Observation // 苹果的新状态管理框架
import Foundation
import UIKit
import ImageIO

// MARK: - 解析场景
/// 每个 case 对应一套指令；session 按场景即取即用（iOS 27 走 Dynamic Profile 路由）。
/// ⚡️ 指令刻意保持精简：端侧模型 prefill 速度有限，指令 token 数直接决定响应延迟
enum ReceiptParseMode {
    /// 小票照片 OCR 文本
    case receipt
    /// 支付页面截图 OCR 文本
    case screenshot
    /// 银行短信文本
    case sms
    /// 账单卡片信息
    case statementCard
    /// 账单单笔交易分类
    case statementTransaction
    /// 账单单个交易块提取
    case statementRow
    /// 账单批量表格提取
    case statementBulk
    /// 小票原图直传（多模态，仅云端 PCC：本地模型图片推理过慢）
    case receiptImage
    /// 支付截图原图直传（多模态，仅云端 PCC）
    case screenshotImage

    var instructions: Instructions {
        switch self {
        case .receipt:
            // ⚠️ 本地 3B 模型对过度压缩的指令敏感：字段清单和金额规则必须逐条列出，
            // 否则会连环漏抽字段（实测：merchant/amount/currency 连环 nil）
            return Instructions {
                "You are an expert receipt data extractor."
                "Extract exact values for: merchant, total amount, currency, date, card last-4 digits, and category from the OCR text."
                "The text is aligned row by row; items on the same row are related."
                "MERCHANT: usually near the top; may be Chinese, Japanese, or English."
                "AMOUNT rules:"
                "- Extract the FINAL PAID amount. Keywords: 实付/已支付/合计/合計/お支払い/請求金額/Total/Grand Total/Amount Due."
                "- If there are discounts (立减/优惠/Discount), use the amount AFTER discount, NOT the subtotal (原价/小计). NEVER sum numbers yourself."
                "- JPY has no decimals: a dot inside a JPY number is a thousands separator ('74.405' -> 74405)."
                "CARD: extract last-4 digits ONLY from an explicit card number (卡号/カードNo/**** masked). Register, table, or receipt numbers are NOT card numbers; if no card number, return nil."
                "CATEGORY: dining=restaurants/cafes/izakaya(居酒屋)/ramen; grocery=supermarkets/7-Eleven/Lawson/FamilyMart/discount stores(ドン・キホーテ); travel=Uber/taxi/flights/hotels/Suica/Shinkansen; digital=electronics/Apple Store/Yodobashi/Bic Camera; anime=anime/manga/game goods(Animate/Melonbooks); streaming=Spotify/Netflix/Disney+/subscriptions; other=anything else."
                "Infer currency from symbols (¥, $, JPY) or location (e.g. Tokyo -> JPY)."
                "Prefer extracting a value that is present in the text; only return nil when the field truly does not appear."
            }
        case .receiptImage:
            return Instructions {
                "You are an expert receipt data extractor."
                "Extract exact values for: merchant, total amount, currency, date, card last-4 digits, and category from the receipt image."
                "MERCHANT: usually near the top; may be Chinese, Japanese, or English."
                "AMOUNT rules:"
                "- Extract the FINAL PAID amount. Keywords: 实付/已支付/合计/合計/お支払い/請求金額/Total/Grand Total/Amount Due."
                "- If there are discounts (立减/优惠/Discount), use the amount AFTER discount, NOT the subtotal (原价/小计). NEVER sum numbers yourself."
                "- JPY has no decimals: a dot inside a JPY number is a thousands separator ('74.405' -> 74405)."
                "CARD: extract last-4 digits ONLY from an explicit card number (卡号/カードNo/**** masked). Register, table, or receipt numbers are NOT card numbers; if no card number, return nil."
                "CATEGORY: dining=restaurants/cafes/izakaya(居酒屋)/ramen; grocery=supermarkets/7-Eleven/Lawson/FamilyMart/discount stores(ドン・キホーテ); travel=Uber/taxi/flights/hotels/Suica/Shinkansen; digital=electronics/Apple Store/Yodobashi/Bic Camera; anime=anime/manga/game goods(Animate/Melonbooks); streaming=Spotify/Netflix/Disney+/subscriptions; other=anything else."
                "Infer currency from symbols (¥, $, JPY) or location (e.g. Tokyo -> JPY)."
                "Prefer extracting a value that is present in the image; only return nil when the field truly does not appear."
            }
        // ⚡️ 精简版；"Today is..." 在 prompt 里按调用时刻生成，
        // 避免长驻单例（OCRService.aiParser）持有过期日期
        case .screenshot:
            return Instructions {
                "You are an expert receipt data extractor for payment screen captures."
                "Extract exact values for: merchant, total amount, currency, date, card last-4 digits, and category from the OCR text."
                "The text is aligned row by row; items on the same row are related."
                "MERCHANT: may be Chinese, Japanese, or English."
                "AMOUNT rules:"
                "- Use the FIRST amount shown on the screen — it is the total billing amount."
                "- IGNORE discounts (立减/优惠/碰一下立减/Discount) below it and any total-without-discount. DO NOT subtract discounts."
                "- JPY has no decimals: a dot inside a JPY number is a thousands separator ('74.405' -> 74405)."
                "CATEGORY: dining=restaurants/cafes/izakaya(居酒屋)/ramen; grocery=supermarkets/7-Eleven/Lawson/FamilyMart/discount stores(ドン・キホーテ); travel=Uber/taxi/flights/hotels/Suica/Shinkansen; digital=electronics/Apple Store/Yodobashi/Bic Camera; anime=anime/manga/game goods(Animate/Melonbooks); streaming=Spotify/Netflix/Disney+/subscriptions; other=anything else."
                "Infer currency from symbols (¥, $, JPY) or location (e.g. Tokyo -> JPY)."
                "Prefer extracting a value that is present in the text; only return nil when the field truly does not appear."
            }
        case .screenshotImage:
            return Instructions {
                "You are an expert receipt data extractor for payment screen captures."
                "Extract exact values for: merchant, total amount, currency, date, card last-4 digits, and category from the screenshot image."
                "MERCHANT: may be Chinese, Japanese, or English."
                "AMOUNT rules:"
                "- Use the FIRST amount shown on the screen — it is the total billing amount."
                "- IGNORE discounts (立减/优惠/碰一下立减/Discount) below it and any total-without-discount. DO NOT subtract discounts."
                "- JPY has no decimals: a dot inside a JPY number is a thousands separator ('74.405' -> 74405)."
                "CATEGORY: dining=restaurants/cafes/izakaya(居酒屋)/ramen; grocery=supermarkets/7-Eleven/Lawson/FamilyMart/discount stores(ドン・キホーテ); travel=Uber/taxi/flights/hotels/Suica/Shinkansen; digital=electronics/Apple Store/Yodobashi/Bic Camera; anime=anime/manga/game goods(Animate/Melonbooks); streaming=Spotify/Netflix/Disney+/subscriptions; other=anything else."
                "Infer currency from symbols (¥, $, JPY) or location (e.g. Tokyo -> JPY)."
                "Prefer extracting a value that is present in the image; only return nil when the field truly does not appear."
            }
        // ⚡️ 精简版：短信文本很短，指令是 prefill 的大头
        case .sms:
            return Instructions {
                "You are an expert transaction extractor for bank SMS notifications."
                "Extract exact values for: merchant, total amount, currency, card last-4 digits, and category from the SMS text."
                "MERCHANT: may be Chinese, Japanese, or English."
                "AMOUNT: the FINAL PAID amount (实付金额/合计/Total)."
                "- JPY has no decimals: a dot inside a JPY number is a thousands separator ('1.100' -> 1100)."
                "CATEGORY: dining=restaurants/cafes/izakaya(居酒屋)/ramen; grocery=supermarkets/7-Eleven/Lawson/FamilyMart/discount stores(ドン・キホーテ); travel=Uber/taxi/flights/hotels/Suica/Shinkansen; digital=electronics/Apple Store/Yodobashi/Bic Camera; anime=anime/manga/game goods(Animate/Melonbooks); streaming=Spotify/Netflix/Disney+/subscriptions; other=anything else."
                "Prefer extracting a value that is present in the text; only return nil when the field truly does not appear."
            }
        case .statementCard:
            return Instructions {
                "You are an expert credit card statement parser."
                "Extract the card product name and the trailing digits of the card number."
                "Return ALL trailing digits exactly as shown after the mask (e.g. if '****71006', return '71006' not '7100')."
                "Do not truncate or pad the digits."
                "If a field is missing, return nil for it."
                "Do not guess. Use only information present in the statement text."
            }
        case .statementTransaction:
            return Instructions {
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
        case .statementRow:
            return Instructions {
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
        case .statementBulk:
            return Instructions {
                "Extract transactions from the markdown table."
                "Skip headers, balances, payments, totals, interest, fees."
                "Dates: YYYY-MM-DD. billingAmount = settled amount."
                "foreignAmount: only if currency conversion shown, else nil."
                "If unsure, return nil."
            }
        }
    }

    /// 云端 PCC 推理档位（仅云端会话生效，本地模型不带推理）：
    /// - moderate：规则推断重的场景 —— 账单交易分类（地区/支付方式/外币金额判定）、
    ///   批量表格提取、小票原图（折扣 vs 实付的陷阱多）
    /// - light：交互式等待的轻抽取，控制延迟
    @available(iOS 27.0, *)
    var cloudReasoningLevel: ContextOptions.ReasoningLevel {
        switch self {
        case .statementTransaction, .statementBulk, .receiptImage:
            return .moderate
        case .receipt, .screenshot, .sms, .statementCard, .statementRow, .screenshotImage:
            return .light
        }
    }
}

// MARK: - 云端通道

/// 「使用云端模型」打开后实际接上的那个远端模型。
/// 各通道都实现了 iOS 27 的 LanguageModel 协议，所以对 session 构造而言完全等价：
/// - Apple PCC：系统内置，端到端加密，无需配置
/// - 第三方：用户选中的服务商（见 Services/ThirdPartyModel/），按协议走手写 adapter
/// - Claude：内置 Claude 服务商，走 Anthropic 官方 ClaudeForFoundationModels 包
@available(iOS 27.0, *)
nonisolated enum CloudRoute {
    case applePCC(PrivateCloudComputeLanguageModel)
    case thirdParty(ThirdPartyLanguageModel)
    case claude(ClaudeLanguageModel)

    /// 当前选中的第三方服务商；没选、没配全、缺密钥都返回 nil（调用方回退本地，不偷偷改走 PCC）
    static func activeThirdParty() -> CloudRoute? {
        guard let provider = ThirdPartyModelStore.activeProvider,
              provider.isComplete,
              let apiKey = ThirdPartyModelStore.apiKey(for: provider.id),
              !apiKey.isEmpty else { return nil }

        if provider.preset == .claude {
            return ClaudeModelCatalog.languageModel(for: provider, apiKey: apiKey).map(CloudRoute.claude)
        }
        return .thirdParty(ThirdPartyLanguageModel(
            config: provider.config,
            apiKey: apiKey,
            displayName: provider.displayName
        ))
    }

    var model: any LanguageModel {
        switch self {
        case .applePCC(let model):    return model
        case .thirdParty(let model):  return model
        case .claude(let model):      return model
        }
    }

    /// 是否可以走图片直传。PCC 一定支持；第三方取决于用户给自己的模型勾了没有；
    /// Claude 由官方包的模型能力表决定。
    var supportsVision: Bool {
        switch self {
        case .applePCC:               return true
        case .thirdParty(let model):  return model.config.supportsVision
        case .claude(let model):      return model.model.capabilities.imageInput
        }
    }

    var logLabel: String {
        switch self {
        case .applePCC:               return "☁️ 使用云端模型 (Private Cloud Compute)"
        case .thirdParty(let model):  return "🔌 使用第三方模型 (\(model.displayName) / \(model.config.modelName))"
        case .claude(let model):      return "🔌 使用第三方模型 (Claude / \(model.model.id))"
        }
    }
}

// MARK: - Dynamic Profile（iOS 27+，WWDC26 Foundation Models）
/// 声明式 Profile：统一路由「场景指令 + 本地/云端模型」。
/// route 非 nil 时整个会话走对应的云端通道；
/// 否则不加 .model 修饰符，使用默认端侧模型。
@available(iOS 27.0, *)
private struct ReceiptParserProfile: LanguageModelSession.DynamicProfile {
    let mode: ReceiptParseMode
    let route: CloudRoute?

    var body: some DynamicProfile {
        if let route {
            // 云端：带按场景分档的推理。
            // 第三方通道会把它映射成各家的推理参数（reasoning_effort / thinking budget）。
            Profile { mode.instructions }
                .model(route.model)
                .reasoningLevel(mode.cloudReasoningLevel)
        } else {
            Profile { mode.instructions }
        }
    }
}

@MainActor
@Observable
final class ReceiptParser {

    init() {}

    // 预热用 session：持有引用避免 prewarm 后立即释放
    private var warmupSession: LanguageModelSession?

    // MARK: - 模型选择（本地 / 云端 Private Cloud Compute）

    /// SettingsView 中"云端模型"开关使用同一个 key
    nonisolated static let cloudModelDefaultsKey = "useCloudAIModel"

    nonisolated private static var isCloudModelEnabled: Bool {
        UserDefaults.standard.bool(forKey: cloudModelDefaultsKey)
    }

    /// 云端开关开启且目标通道就绪时返回该通道，否则 nil（调用方回退本地）。
    /// 两条通道都需要 iOS 27+；PCC 另需 com.apple.developer.private-cloud-compute 受管权限。
    @available(iOS 27.0, *)
    nonisolated static func activeCloudRoute() -> CloudRoute? {
        guard isCloudModelEnabled else { return nil }

        switch ThirdPartyModelStore.backend {
        case .thirdParty:
            // 第三方没配全就回退本地，不再偷偷走 PCC：
            // 用户明确选了自己的服务，静默换成别家会让「数据发去哪」变得不可预期
            return CloudRoute.activeThirdParty()
        case .applePCC:
            let model = PrivateCloudComputeLanguageModel()
            return model.isAvailable ? .applePCC(model) : nil
        }
    }

    /// 多模态（图片直传）解析是否可用。
    /// ⚡️ 本地模型跑图片输入过慢，刻意只在云端就绪时开放多模态。
    nonisolated static var isMultimodalAvailable: Bool {
        if #available(iOS 27.0, *) {
            return activeCloudRoute()?.supportsVision ?? false
        }
        return false
    }

    /// 按场景创建 session：
    /// - iOS 27+ 云端：Dynamic Profile 声明式选择指令与模型
    /// - 本地（含 iOS 26）：传统 instructions init
    /// 返回 session 及其是否为云端：本地与云端各有验证过的 prompt 配方
    /// （本地裸文本、云端带前导语），调用方据 isCloud 分流。
    private func makeSession(mode: ReceiptParseMode) -> (session: LanguageModelSession, isCloud: Bool) {
        if #available(iOS 27.0, *) {
            let route = Self.activeCloudRoute()
            if Self.isCloudModelEnabled {
                print(route?.logLabel
                      ?? "⚠️ 云端模型不可用（未配置/未授权/无网络/系统未就绪），回退本地模型")
            }
            if let route {
                // Dynamic Profile 只用于云端：它的增量价值只有 reasoningLevel 档位
                return (LanguageModelSession(profile: ReceiptParserProfile(mode: mode, route: route)), true)
            }
        }
        // ⚠️ 本地一律走经典 instructions 构造，不走 Dynamic Profile：
        // profile 路由在本地没有任何增量功能，且属于"本地字段连环 nil"故障的
        // 排查变量之一（beta 端侧 profile 会话的指令注入行为未经验证）
        return (LanguageModelSession(instructions: mode.instructions), false)
    }

    /// 云端沿用历史验证过的前导语（本地模型会被它带偏，云端一直工作良好）
    nonisolated private static let cloudPreamble = "Please analyze the following text carefully. It may contain non-English characters such as Chinese or Japanese, but you must process it as part of this English prompt:"

    /// 字段值消毒：云端 beta 偶发在 JSON 里输出全角引号，解析后字段尾部
    /// 会残留 「”, 」 之类的残渣；统一剥掉两端的引号/逗号/空白，空串归 nil。
    nonisolated static func sanitized(_ metadata: ReceiptMetadata) -> ReceiptMetadata {
        var result = metadata
        result.merchant = cleanedString(result.merchant)
        result.currency = cleanedString(result.currency)?.uppercased()
        result.dateString = cleanedString(result.dateString)
        result.cardLast4 = cleanedString(result.cardLast4)
        return result
    }

    nonisolated private static func cleanedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let junk = CharacterSet(charactersIn: "\"“”„'‘’｢｣「」,，、 \t\n")
        let cleaned = value.trimmingCharacters(in: junk)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 本地小模型见 ¥ 常猜 JPY（CNY/JPY 混淆）：全文没有任何日本迹象、又有中国大陆迹象时纠正为 CNY。
    /// 同屏有别的外币也照样纠正（银联「-¥7.33（HK$8.60）」里的 ¥ 是人民币入账金额）。
    /// 只用于本地模型——云端 / 第三方模型的币种判断可靠，不能拿界面用语去推翻它。
    static func correctingLocalYenGuess(_ metadata: ReceiptMetadata, text: String) -> ReceiptMetadata {
        guard let currency = metadata.currency,
              Region.from(currencyText: currency) == .jp,
              !OCRService.hasJapaneseEvidence(in: text),
              OCRService.hasMainlandEvidence(in: text) else { return metadata }
        print("🧰 本地模型 ¥ 纠偏: \(currency) → CNY")
        var result = metadata
        result.currency = Region.cn.currencyCode
        return result
    }

    /// 多模态 session：仅云端 PCC，云端不可用直接抛错（调用方回退 OCR 文本管线）
    @available(iOS 27.0, *)
    private func makeMultimodalSession(mode: ReceiptParseMode) throws -> LanguageModelSession {
        guard let route = Self.activeCloudRoute(),
              route.supportsVision else {
            throw NSError(
                domain: "ReceiptParser",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: String.loc("云端模型不可用，无法使用图像解析")]
            )
        }
        print("🖼️ \(route.logLabel) —— 多模态直传")
        return LanguageModelSession(profile: ReceiptParserProfile(mode: mode, route: route))
    }

    /// 检查 Apple Intelligence 是否可用；不可用时抛出带用户可读原因的错误。
    /// 所有 parse 方法调用模型前统一走这里，避免在不支持的设备上静默失败。
    nonisolated static func ensureModelAvailable() throws {
        // 云端模式且通道可用时直接放行（makeSession 会选择云端模型）；
        // 否则继续检查本地模型作为兜底路径
        if #available(iOS 27.0, *), activeCloudRoute() != nil {
            return
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            let message: String
            switch reason {
            case .deviceNotEligible:
                message = String.loc("此设备不支持 Apple Intelligence")
            case .appleIntelligenceNotEnabled:
                message = String.loc("请在系统设置中开启 Apple Intelligence")
            case .modelNotReady:
                message = String.loc("Apple Intelligence 模型尚未就绪，请稍后再试")
            @unknown default:
                message = String.loc("Apple Intelligence 暂不可用")
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
        if #available(iOS 27.0, *), Self.activeCloudRoute() != nil { return }
        guard case .available = SystemLanguageModel.default.availability else { return }
        let session = LanguageModelSession(instructions: ReceiptParseMode.receipt.instructions)
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

    // MARK: - 文本解析（OCR / 短信 / 账单）

    func parse(text: String) async throws -> ReceiptMetadata {
            try Self.ensureModelAvailable()

            // 👇👇👇 核心修改：每次调用 parse 时，创建一个全新的 session！
            // 这样每次都是“第一次”，没有历史包袱
            let (session, isCloud) = makeSession(mode: .receipt)

            // ⚠️ prompt 按模型分流（各用各的真机验证配方）：
            // - 本地：只放小票文本。旧前导语会让 iOS 27 beta 本地模型
            //   对判断型字段连环输出 nil（四探针诊断证实）
            // - 云端：保留前导语+分隔标记，云端一直用它工作良好
            let metadata: ReceiptMetadata
            if isCloud {
                metadata = try await session.respond(generating: CloudReceiptMetadata.self) {
                    Self.cloudPreamble
                    "=== START OF RECEIPT DATA ==="
                    text
                    "=== END OF RECEIPT DATA ==="
                }.content.asReceiptMetadata
            } else {
                metadata = try await session.respond(generating: ReceiptMetadata.self) {
                    text
                }.content
            }

        var cleaned = Self.sanitized(metadata)
        if !isCloud { cleaned = Self.correctingLocalYenGuess(cleaned, text: text) }
        Self.logReceiptFields(cleaned, label: "OCR")
        return cleaned
    }

    /// 支付截图 OCR 文本解析。云端额外返回模型标出的原币 / 入账两侧（同屏两种币种时），本地恒为 nil
    func parseScreenshot(text: String) async throws -> (metadata: ReceiptMetadata, conversion: CurrencyConversion?) {
        try Self.ensureModelAvailable()
        let (session, isCloud) = makeSession(mode: .screenshot)
        let today = Date().formatted(date: .abbreviated, time: .omitted)

        // 同 parse()：prompt 按模型分流；日期提示两边都保留。
        // 云端用 CloudPaymentMetadata，多出的原币 / 入账字段让模型自己分清两种币种
        let metadata: ReceiptMetadata
        var conversion: CurrencyConversion?
        if isCloud {
            let content = try await session.respond(generating: CloudPaymentMetadata.self) {
                "Today is \(today). If no date is found in the text, use today."
                Self.cloudPreamble
                "=== START OF SCREENSHOT DATA ==="
                text
                "=== END OF SCREENSHOT DATA ==="
            }.content
            metadata = content.asReceiptMetadata
            conversion = Self.conversion(from: content)
        } else {
            metadata = try await session.respond(generating: ReceiptMetadata.self) {
                "Today is \(today). If no date is found in the text, use today."
                text
            }.content
        }

        var cleaned = Self.sanitized(metadata)
        if !isCloud { cleaned = Self.correctingLocalYenGuess(cleaned, text: text) }
        Self.logReceiptFields(cleaned, label: "Screenshot OCR")
        Self.logConversion(conversion, label: "Screenshot OCR")
        return (cleaned, conversion)
    }

    /// 银行短信解析。云端额外返回模型标出的原币 / 入账两侧（「消费HKD8.60，折合人民币7.33元」），本地恒为 nil
    func SMSparse(text: String) async throws -> (metadata: ReceiptMetadata, conversion: CurrencyConversion?) {
            try Self.ensureModelAvailable()

            // 👇👇👇 核心修改：每次调用 parse 时，创建一个全新的 session！
            // 这样每次都是“第一次”，没有历史包袱
            let (session, isCloud) = makeSession(mode: .sms)

            // 同 parse()：prompt 按模型分流
            let metadata: ReceiptMetadata
            var conversion: CurrencyConversion?
            if isCloud {
                let content = try await session.respond(generating: CloudPaymentMetadata.self) {
                    Self.cloudPreamble
                    "=== START OF SMS DATA ==="
                    text
                    "=== END OF SMS DATA ==="
                }.content
                metadata = content.asReceiptMetadata
                conversion = Self.conversion(from: content)
            } else {
                metadata = try await session.respond(generating: ReceiptMetadata.self) {
                    text
                }.content
            }

        var cleaned = Self.sanitized(metadata)
        if !isCloud { cleaned = Self.correctingLocalYenGuess(cleaned, text: text) }
        Self.logReceiptFields(cleaned, label: "SMS")
        Self.logConversion(conversion, label: "SMS")
        return (cleaned, conversion)
        }

    /// 云端模型标出的原币 / 入账两侧 → CurrencyConversion；金额缺失或币种认不出的一侧当没有
    static func conversion(from content: CloudPaymentMetadata) -> CurrencyConversion? {
        func side(_ amount: Double?, _ currency: String?) -> CurrencyAmount? {
            guard let amount, amount != 0,
                  let code = cleanedString(currency),
                  let region = Region.from(currencyText: code) else { return nil }
            return CurrencyAmount(amount: abs(amount), region: region)
        }
        let original = side(content.originalAmount, content.originalCurrency)
        let billing = side(content.billingAmount, content.billingCurrency)
        guard original != nil || billing != nil else { return nil }
        return CurrencyConversion(original: original, billing: billing)
    }

    private static func logConversion(_ conversion: CurrencyConversion?, label: String) {
        guard let conversion else { return }
        func describe(_ side: CurrencyAmount?) -> String {
            side.map { "\($0.region.currencyCode) \(String(format: "%.2f", $0.amount))" } ?? "nil"
        }
        print("\(label) conversion: original=\(describe(conversion.original)), billing=\(describe(conversion.billing))")
    }

    // MARK: - 多模态解析（图片直传，仅云端 PCC）

    /// UIImage → Attachment：显式走 CGImage 构造器（与运行时符号探测的符号严格一致），
    /// 避免依赖 UIKit overlay 的额外符号。
    @available(iOS 27.0, *)
    private static func makeImageAttachment(_ image: UIImage) throws -> Attachment<ImageAttachmentContent> {
        guard let cgImage = image.cgImage else {
            throw NSError(
                domain: "ReceiptParser",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: String.loc("无法读取图片数据")]
            )
        }
        return Attachment(cgImage, orientation: OCRService.cgImageOrientation(from: image.imageOrientation))
    }

    /// 小票原图直传云端解析；云端不可用时抛错，调用方应回退 OCR 文本管线。
    @available(iOS 27.0, *)
    func parseReceiptImage(_ image: UIImage) async throws -> ReceiptMetadata {
        let session = try makeMultimodalSession(mode: .receiptImage)
        let attachment = try Self.makeImageAttachment(image)

        let response = try await session.respond(
            generating: CloudReceiptMetadata.self,
            options: GenerationOptions(samplingMode: .greedy)
        ) {
            "Analyze this receipt image carefully. It may contain Chinese, Japanese, or English text."
            attachment
        }

        let metadata = Self.sanitized(response.content.asReceiptMetadata)
        Self.logReceiptFields(metadata, label: "🖼️ Receipt image")
        return metadata
    }

    /// 支付截图原图直传云端解析；云端不可用时抛错，调用方应回退 OCR 文本管线。
    /// 同 parseScreenshot：另返回模型标出的原币 / 入账两侧
    @available(iOS 27.0, *)
    func parseScreenshotImage(_ image: UIImage) async throws -> (metadata: ReceiptMetadata, conversion: CurrencyConversion?) {
        let session = try makeMultimodalSession(mode: .screenshotImage)
        let attachment = try Self.makeImageAttachment(image)
        let today = Date().formatted(date: .abbreviated, time: .omitted)

        let response = try await session.respond(
            generating: CloudPaymentMetadata.self,
            options: GenerationOptions(samplingMode: .greedy)
        ) {
            "Today is \(today). If no date is visible in the screenshot, use today."
            "Analyze this payment screenshot carefully. It may contain Chinese, Japanese, or English text."
            attachment
        }

        let metadata = Self.sanitized(response.content.asReceiptMetadata)
        let conversion = Self.conversion(from: response.content)
        Self.logReceiptFields(metadata, label: "🖼️ Screenshot image")
        Self.logConversion(conversion, label: "🖼️ Screenshot image")
        return (metadata, conversion)
    }

    nonisolated private static func logReceiptFields(_ metadata: ReceiptMetadata, label: String) {
        let amountText = metadata.totalAmount.map { String(format: "%.2f", $0) } ?? "nil"
        print("\(label) fields: merchant=\(metadata.merchant ?? "nil"), amount=\(amountText), currency=\(metadata.currency ?? "nil"), date=\(metadata.dateString ?? "nil"), cardLast4=\(metadata.cardLast4 ?? "nil"), category=\(metadata.category?.rawValue ?? "nil")")
    }

    // MARK: - 账单解析

    func parseStatementCard(text: String) async throws -> StatementCardMetadata {
        try Self.ensureModelAvailable()
        let session = makeSession(mode: .statementCard).session
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
        let session = makeSession(mode: .statementTransaction).session
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
        let session = makeSession(mode: .statementRow).session
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
        let session = makeSession(mode: .statementBulk).session
        let response = try await session.respond(
            generating: StatementRowTransactionList.self
        ) {
            "Analyze these statement tables:"
            text
        }

        return response.content
    }

}
