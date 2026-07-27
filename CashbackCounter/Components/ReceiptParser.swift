//
//  AppleIntelligenceService.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//
import FoundationModels
import Observation // 苹果的新状态管理框架
import Foundation
import UIKit
import ImageIO

// MARK: - Beta 运行时符号探测
/// SDK（27A5194q）的 swiftinterface 声明了 Dynamic Profile / Attachment 等 iOS 27 符号，
/// 但旧版 iOS 27 beta 的 FoundationModels 二进制里还没有它们。
/// 部署目标 26.0 会把这些符号弱链接：运行时缺失时解析为 null，一调用就 EXC_BAD_ACCESS(address=0x0)，
/// 而 `#available(iOS 27.0, *)` 无法区分同一大版本不同 beta 之间的符号差异。
/// 因此对每个新符号调用点做一次性 dlsym 探测，缺失即回退。
/// 设备升级到与 SDK 匹配的 beta 后探测自动通过；iOS 27 正式版发布后可整段删除。
private enum FoundationModelsRuntime {
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    private static func has(_ symbol: String) -> Bool {
        dlsym(rtldDefault, symbol) != nil
    }

    /// Dynamic Profile 构建链：DynamicInstructionsBuilder.buildExpression、
    /// DynamicProfileBuilder.buildBlock / buildEither（body 里 if/else 分支所需）
    static let dynamicProfileAvailable: Bool = {
        let ok = has("$s16FoundationModels26DynamicInstructionsBuilderV15buildExpressionyxxAA0cD0RzlFZ")
            && has("$s16FoundationModels20LanguageModelSessionC21DynamicProfileBuilderV10buildBlockyxxAC0fG0RzlFZ")
            && has("$s16FoundationModels20LanguageModelSessionC21DynamicProfileBuilderV11buildEither5firstAC011ConditionalfG0Vy_xq_Gx_tAC0fG0RzAcKR_r0_lFZ")
        if !ok {
            print("⚠️ 系统 FoundationModels 缺少 Dynamic Profile 符号（beta 低于 SDK），回退传统 session 构造")
        }
        return ok
    }()

    /// 泛型 init(model: some LanguageModel, tools:, instructions:)：云端 session 的传统构造方式，同为 iOS 27 新符号
    static let cloudSessionInitAvailable: Bool = {
        let ok = has("$s16FoundationModels20LanguageModelSessionC5model5tools12instructionsACx_SayAA4Tool_pGAA12InstructionsVSgtcAA0cD0RzlufC")
        if !ok {
            print("⚠️ 系统 FoundationModels 缺少泛型 session init 符号（beta 低于 SDK），云端模型整体禁用")
        }
        return ok
    }()

    /// Attachment(CGImage, orientation:)：多模态图片直传所需
    static let imageAttachmentAvailable: Bool = {
        let ok = has("$s16FoundationModels10AttachmentVA2A05ImageC7ContentVRszrlE_11orientationACyAEGSo10CGImageRefa_So0G19PropertyOrientationVSgtcfC")
        if !ok {
            print("⚠️ 系统 FoundationModels 缺少 Attachment 符号（beta 低于 SDK），多模态解析不可用")
        }
        return ok
    }()

    /// DynamicProfile.reasoningLevel 修饰符：这组 API 在 beta 间改过名（早期叫 thinkingEffort），
    /// 与 builder 符号不一定同批存在，单独探测。缺失时云端会话不带推理档位，其余功能不受影响。
    static let reasoningModifierAvailable: Bool = {
        let ok = has("$s16FoundationModels20LanguageModelSessionC14DynamicProfilePAAE14reasoningLevelyQrAA14ContextOptionsV09ReasoningI0OSgF")
        if !ok {
            print("⚠️ 系统 FoundationModels 缺少 reasoningLevel 符号（beta 低于 SDK），云端推理档位不生效")
        }
        return ok
    }()
}

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

// MARK: - Dynamic Profile（iOS 27+，WWDC26 Foundation Models）
/// 声明式 Profile：统一路由「场景指令 + 本地/云端模型」。
/// cloudModel 非 nil 时整个会话走 Private Cloud Compute；
/// 否则不加 .model 修饰符，使用默认端侧模型。
@available(iOS 27.0, *)
private struct ReceiptParserProfile: LanguageModelSession.DynamicProfile {
    let mode: ReceiptParseMode
    let cloudModel: PrivateCloudComputeLanguageModel?

    var body: some DynamicProfile {
        if let cloudModel {
            // 云端 PCC：带按场景分档的推理（旧 beta 运行时缺 reasoningLevel 符号则不加档位）
            if FoundationModelsRuntime.reasoningModifierAvailable {
                Profile { mode.instructions }
                    .model(cloudModel)
                    .reasoningLevel(mode.cloudReasoningLevel)
            } else {
                Profile { mode.instructions }
                    .model(cloudModel)
            }
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

    /// 云端开关开启且 PCC 就绪时返回云端模型，否则 nil（调用方回退本地）。
    /// 云端需要 iOS 27+ 及 com.apple.developer.private-cloud-compute 受管权限。
    /// beta 运行时缺少泛型 session init 符号时整体禁用云端，避免空符号调用崩溃。
    @available(iOS 27.0, *)
    nonisolated private static func activeCloudModel() -> PrivateCloudComputeLanguageModel? {
        guard isCloudModelEnabled,
              FoundationModelsRuntime.cloudSessionInitAvailable else { return nil }
        let model = PrivateCloudComputeLanguageModel()
        return model.isAvailable ? model : nil
    }

    /// 多模态（图片直传）解析是否可用。
    /// ⚡️ 本地模型跑图片输入过慢，刻意只在云端 PCC 就绪时开放多模态；
    /// 另需系统运行时具备 Attachment 符号（旧 beta 缺失）。
    nonisolated static var isMultimodalAvailable: Bool {
        if #available(iOS 27.0, *) {
            return FoundationModelsRuntime.imageAttachmentAvailable && activeCloudModel() != nil
        }
        return false
    }

    /// 按场景创建 session：
    /// - iOS 27+ 且运行时具备 Dynamic Profile 符号：声明式选择指令与模型
    /// - 其余（iOS 26 或旧 beta 运行时）：传统构造；云端走泛型 init，本地走 instructions init
    private func makeSession(mode: ReceiptParseMode) -> LanguageModelSession {
        if #available(iOS 27.0, *) {
            let cloud = Self.activeCloudModel()
            if Self.isCloudModelEnabled {
                print(cloud != nil
                      ? "☁️ 使用云端模型 (Private Cloud Compute)"
                      : "⚠️ 云端模型不可用（未授权/无网络/系统未就绪），回退本地模型")
            }
            if let cloud {
                // Dynamic Profile 只用于云端：它的增量价值只有 reasoningLevel 档位
                if FoundationModelsRuntime.dynamicProfileAvailable {
                    return LanguageModelSession(profile: ReceiptParserProfile(mode: mode, cloudModel: cloud))
                }
                return LanguageModelSession(model: cloud, instructions: mode.instructions)
            }
        }
        // ⚠️ 本地一律走经典 instructions 构造，不走 Dynamic Profile：
        // profile 路由在本地没有任何增量功能，且属于"本地字段连环 nil"故障的
        // 排查变量之一（beta 端侧 profile 会话的指令注入行为未经验证）
        return LanguageModelSession(instructions: mode.instructions)
    }

    /// 多模态 session：仅云端 PCC，云端不可用直接抛错（调用方回退 OCR 文本管线）
    @available(iOS 27.0, *)
    private func makeMultimodalSession(mode: ReceiptParseMode) throws -> LanguageModelSession {
        guard FoundationModelsRuntime.imageAttachmentAvailable,
              let cloud = Self.activeCloudModel() else {
            throw NSError(
                domain: "ReceiptParser",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "云端模型不可用，无法使用图像解析")]
            )
        }
        print("☁️🖼️ 使用云端多模态解析 (Private Cloud Compute)")
        if FoundationModelsRuntime.dynamicProfileAvailable {
            return LanguageModelSession(profile: ReceiptParserProfile(mode: mode, cloudModel: cloud))
        }
        return LanguageModelSession(model: cloud, instructions: mode.instructions)
    }

    /// 检查 Apple Intelligence 是否可用；不可用时抛出带用户可读原因的错误。
    /// 所有 parse 方法调用模型前统一走这里，避免在不支持的设备上静默失败。
    nonisolated static func ensureModelAvailable() throws {
        // 云端模式且 PCC 可用时直接放行（makeSession 会选择云端模型）；
        // 否则继续检查本地模型作为兜底路径
        if #available(iOS 27.0, *), activeCloudModel() != nil {
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
        if #available(iOS 27.0, *), Self.activeCloudModel() != nil { return }
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
            let session = makeSession(mode: .receipt)

            // ⚠️ prompt 只放小票文本本身，不加英文前导语和分隔标记：
            // 真机诊断证实旧前导语（"process it as part of this English prompt"）
            // 会让 iOS 27 beta 本地模型对判断型字段连环输出 nil；
            // 同理不用贪心采样，默认采样是验证过的行为
            let response = try await session.respond(
                generating: ReceiptMetadata.self
            ) {
                text
            }

        let metadata = response.content
        Self.logReceiptFields(metadata, label: "OCR")
        return metadata
    }

    func parseScreenshot(text: String) async throws -> ReceiptMetadata {
        try Self.ensureModelAvailable()
        let session = makeSession(mode: .screenshot)
        let today = Date().formatted(date: .abbreviated, time: .omitted)

        // 同 parse()：不加前导语/分隔标记，只保留日期提示一句
        let response = try await session.respond(
            generating: ReceiptMetadata.self
        ) {
            "Today is \(today). If no date is found in the text, use today."
            text
        }

        let metadata = response.content
        Self.logReceiptFields(metadata, label: "Screenshot OCR")
        return metadata
    }

    func SMSparse(text: String) async throws -> ReceiptMetadata {
            try Self.ensureModelAvailable()

            // 👇👇👇 核心修改：每次调用 parse 时，创建一个全新的 session！
            // 这样每次都是“第一次”，没有历史包袱
            let session = makeSession(mode: .sms)

            // 同 parse()：不加前导语/分隔标记
            let response = try await session.respond(
                generating: ReceiptMetadata.self
            ) {
                text
            }

        let metadata = response.content
        Self.logReceiptFields(metadata, label: "SMS")
        return metadata
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
                userInfo: [NSLocalizedDescriptionKey: String(localized: "无法读取图片数据")]
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
            generating: ReceiptMetadata.self,
            options: GenerationOptions(samplingMode: .greedy)
        ) {
            "Analyze this receipt image carefully. It may contain Chinese, Japanese, or English text."
            attachment
        }

        let metadata = response.content
        Self.logReceiptFields(metadata, label: "🖼️ Receipt image")
        return metadata
    }

    /// 支付截图原图直传云端解析；云端不可用时抛错，调用方应回退 OCR 文本管线。
    @available(iOS 27.0, *)
    func parseScreenshotImage(_ image: UIImage) async throws -> ReceiptMetadata {
        let session = try makeMultimodalSession(mode: .screenshotImage)
        let attachment = try Self.makeImageAttachment(image)
        let today = Date().formatted(date: .abbreviated, time: .omitted)

        let response = try await session.respond(
            generating: ReceiptMetadata.self,
            options: GenerationOptions(samplingMode: .greedy)
        ) {
            "Today is \(today). If no date is visible in the screenshot, use today."
            "Analyze this payment screenshot carefully. It may contain Chinese, Japanese, or English text."
            attachment
        }

        let metadata = response.content
        Self.logReceiptFields(metadata, label: "🖼️ Screenshot image")
        return metadata
    }

    nonisolated private static func logReceiptFields(_ metadata: ReceiptMetadata, label: String) {
        let amountText = metadata.totalAmount.map { String(format: "%.2f", $0) } ?? "nil"
        print("\(label) fields: merchant=\(metadata.merchant ?? "nil"), amount=\(amountText), currency=\(metadata.currency ?? "nil"), date=\(metadata.dateString ?? "nil"), cardLast4=\(metadata.cardLast4 ?? "nil"), category=\(metadata.category?.rawValue ?? "nil")")
    }

    // MARK: - 账单解析

    func parseStatementCard(text: String) async throws -> StatementCardMetadata {
        try Self.ensureModelAvailable()
        let session = makeSession(mode: .statementCard)
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
        let session = makeSession(mode: .statementTransaction)
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
        let session = makeSession(mode: .statementRow)
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
        let session = makeSession(mode: .statementBulk)
        let response = try await session.respond(
            generating: StatementRowTransactionList.self
        ) {
            "Analyze these statement tables:"
            text
        }

        return response.content
    }

}
