//
//  FeedbackService.swift
//  CashbackCounter
//
//  新卡建议与意见反馈：都提交到自建后端，开发者在后端的 /feedback 管理页上看。
//
//  两个端点的登录要求不一样（后端 SecurityConfig 里定死的）：
//    - 新卡建议必须登录 —— 带会话 token 走 PlaidAPIClient 的常规入口
//    - 反馈可以匿名 —— 登录本身出了问题的用户也得有地方说。
//      登录了就带上身份（记在账号名下），没登录走免认证入口。
//

import Foundation
import UIKit

// MARK: - 长度上限

/// 和后端 FeedbackService 里的常量一一对应。改一边必须改另一边 ——
/// 否则用户在本地输得进去，提交时却被后端 400 拒掉。
enum FeedbackLimits {
    static let bankName = 100
    static let cardName = 100
    static let rewardInfo = 2000
    static let message = 4000
    static let contact = 200

    /// 把文本截到上限以内。
    ///
    /// 按 Unicode 码点数算：后端按码点校验，Postgres 的 varchar(n) 数的也是它。
    /// 用 `count`（字素簇）会放过一面国旗 = 2 个码点这种情况；用 `utf16.count` 又会把
    /// emoji 多算一倍。截的时候每次删整个字符，不会把一个 emoji 切成半个。
    static func clamp(_ text: String, to limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var clamped = String(text.prefix(limit))
        while clamped.unicodeScalars.count > limit {
            clamped.removeLast()
        }
        return clamped
    }
}

// MARK: - 提交内容

/// 反馈分类。rawValue 就是发给后端的值；后端认不出的会按 other 收下。
enum FeedbackCategory: String, CaseIterable, Identifiable, Encodable {
    case bug
    case suggestion
    case other

    var id: Self { self }

    var displayName: String {
        switch self {
        case .bug: return String.loc("问题")
        case .suggestion: return String.loc("建议")
        case .other: return String.loc("其他")
        }
    }
}

/// 提交时自动附带的诊断信息。两个提交页上都写明了会附带这些，
/// 反馈页还把具体值列了出来 —— 都不是能认出人的信息。
struct SubmissionDiagnostics: Encodable, Equatable {
    /// "2.7 (45)"：版本号加构建号。同一个版本号的 TestFlight 包可能有好几个
    let appVersion: String
    /// "iOS 27.0.1"
    let osVersion: String
    /// "iPhone18,2"。UIDevice.model 只会给一个 "iPhone"，排查机型相关的问题用不上
    let deviceModel: String
    /// App 当前生效的语言（"zh-Hans" / "zh-Hant" / "en"），不是系统语言
    let language: String

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case language
    }

    static func current() -> SubmissionDiagnostics {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        return SubmissionDiagnostics(
            appVersion: "\(version) (\(build))",
            osVersion: "\(device.systemName) \(device.systemVersion)",
            deviceModel: deviceModelIdentifier(),
            language: AppLanguage.languageCode)
    }

    private static func deviceModelIdentifier() -> String {
        #if targetEnvironment(simulator)
        // 模拟器上 uname 只会给出 Mac 的 "arm64"
        let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown"
        return "\(simulated) (Simulator)"
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
    }
}

/// POST /api/card-requests 的请求体。字段名是后端 @JsonProperty 定的下划线命名
struct CardRequestSubmission: Encodable {
    let bankName: String
    let cardName: String
    /// Region 的 rawValue（"美国"），和卡片模板里的写法一致。用户没选就不发
    let region: String?
    /// 返现 / 积分规则的自由文本，没填就不发
    let rewardInfo: String?
    let diagnostics: SubmissionDiagnostics

    enum CodingKeys: String, CodingKey {
        case bankName = "bank_name"
        case cardName = "card_name"
        case region
        case rewardInfo = "reward_info"
        case diagnostics
    }
}

/// POST /api/feedback 的请求体
struct FeedbackSubmission: Encodable {
    let category: FeedbackCategory
    let message: String
    /// 用户自愿留下的联系方式，没填就不发
    let contact: String?
    let diagnostics: SubmissionDiagnostics
}

// MARK: - 提交

@MainActor
final class FeedbackService {

    static let shared = FeedbackService()

    private let api = PlaidAPIClient.shared

    private init() {}

    /// 新卡建议。**必须已登录**：没有会话 token 时 PlaidAPIClient 直接抛 `.notSignedIn`，
    /// 请求根本不会发出去。后端那边同样要求登录，这里不是唯一的闸。
    func submitCardRequest(_ submission: CardRequestSubmission) async throws {
        let _: EmptyResponse = try await api.post("/api/card-requests", body: submission)
    }

    /// 意见反馈。登录了就记在这个账号名下，没登录就匿名。
    ///
    /// 已登录但会话过期时，走的是和其它请求一样的 401 续期流程（会弹一次 Apple 授权），
    /// 而不是悄悄降级成匿名 —— 用户以为自己是署名提交的，就不该被偷偷改成匿名。
    func submitFeedback(_ submission: FeedbackSubmission) async throws {
        if AuthService.shared.isSignedIn {
            let _: EmptyResponse = try await api.post("/api/feedback", body: submission)
        } else {
            let _: EmptyResponse = try await api.postUnauthenticated("/api/feedback", body: submission)
        }
    }

    /// 提交失败时给用户看的话。
    ///
    /// 429 单独翻译：后端的文案只有中文，而限频是普通用户最可能碰到的那个错误。
    /// 其余情况沿用 PlaidAPIError 的描述（后端给的 message 优先）。
    static func userMessage(for error: Error) -> String {
        if let apiError = error as? PlaidAPIError, case .server(429, _) = apiError {
            return String.loc("提交太频繁了，请稍后再试")
        }
        return error.localizedDescription
    }
}
