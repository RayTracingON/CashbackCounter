import UIKit
import XCTest
@testable import CashbackCounter

/// 新卡建议 / 意见反馈的请求体与本地截断。
///
/// 这些坏了都不会崩：字段名和后端对不上，后端收到的是 null，用户看到的是莫名其妙的
/// "请填写银行名称"；截断规则和后端的上限对不上，用户在本地输得进去、提交时却被拒。
@MainActor
final class FeedbackServiceTests: XCTestCase {

    private let diagnostics = SubmissionDiagnostics(
        appVersion: "2.7 (45)", osVersion: "iOS 27.0", deviceModel: "iPhone18,2", language: "zh-Hans")

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 请求体

    /// 键名是后端 FeedbackController 里 @JsonProperty 定的下划线命名
    func testCardRequestUsesBackendFieldNames() throws {
        let body = try jsonObject(CardRequestSubmission(
            bankName: "Chase", cardName: "Freedom Flex", region: Region.us.rawValue,
            rewardInfo: "5% 季度轮换", diagnostics: diagnostics))

        XCTAssertEqual(body["bank_name"] as? String, "Chase")
        XCTAssertEqual(body["card_name"] as? String, "Freedom Flex")
        XCTAssertEqual(body["region"] as? String, "美国", "地区发 rawValue，和卡片模板 JSON 的写法一致")
        XCTAssertEqual(body["reward_info"] as? String, "5% 季度轮换")

        let diag = try XCTUnwrap(body["diagnostics"] as? [String: Any])
        XCTAssertEqual(diag["app_version"] as? String, "2.7 (45)")
        XCTAssertEqual(diag["os_version"] as? String, "iOS 27.0")
        XCTAssertEqual(diag["device_model"] as? String, "iPhone18,2")
        XCTAssertEqual(diag["language"] as? String, "zh-Hans")
    }

    /// 没填的选填项不发键，后端那边就是 null，而不是一个空串
    func testEmptyOptionalFieldsAreOmitted() throws {
        let card = try jsonObject(CardRequestSubmission(
            bankName: "A", cardName: "B", region: nil, rewardInfo: nil, diagnostics: diagnostics))
        XCTAssertNil(card["region"])
        XCTAssertNil(card["reward_info"])

        let feedback = try jsonObject(FeedbackSubmission(
            category: .bug, message: "m", contact: nil, diagnostics: diagnostics))
        XCTAssertNil(feedback["contact"])
        XCTAssertEqual(feedback["message"] as? String, "m")
    }

    /// 后端 FeedbackService.CATEGORIES 只认这三个，认不出的会被当成 other
    func testFeedbackCategoryRawValuesMatchBackend() throws {
        XCTAssertEqual(FeedbackCategory.allCases.map(\.rawValue), ["bug", "suggestion", "other"])

        let body = try jsonObject(FeedbackSubmission(
            category: .suggestion, message: "m", contact: "me@example.com", diagnostics: diagnostics))
        XCTAssertEqual(body["category"] as? String, "suggestion")
        XCTAssertEqual(body["contact"] as? String, "me@example.com")
    }

    // MARK: - 截断

    /// 后端按 Unicode 码点校验长度，本地截断必须用同一把尺子
    func testClampCountsUnicodeScalarsLikeTheBackend() {
        XCTAssertEqual(FeedbackLimits.clamp("abc", to: 5), "abc")
        XCTAssertEqual(FeedbackLimits.clamp("abcdef", to: 5), "abcde")

        // 🇺🇸 是 1 个字符、2 个码点："a🇺🇸b" 共 4 个码点，上限 3 只能留下 "a🇺🇸"
        XCTAssertEqual(FeedbackLimits.clamp("a🇺🇸b", to: 3), "a🇺🇸")
        // 放不下整面国旗时整个去掉，不切成半个
        XCTAssertEqual(FeedbackLimits.clamp("a🇺🇸", to: 2), "a")

        let longEmoji = String(repeating: "🏦", count: 150)
        XCTAssertEqual(FeedbackLimits.clamp(longEmoji, to: FeedbackLimits.cardName).unicodeScalars.count,
                       FeedbackLimits.cardName)
    }

    // MARK: - 错误文案

    /// 429 的后端文案只有中文，要换成本地化的说法；其余错误沿用后端给的 message
    func testRateLimitGetsLocalizedMessage() {
        let limited = FeedbackService.userMessage(
            for: PlaidAPIError.server(status: 429, message: "今天提交的反馈已经很多了，请明天再来"))
        XCTAssertEqual(limited, String.loc("提交太频繁了，请稍后再试"))

        let invalid = FeedbackService.userMessage(
            for: PlaidAPIError.server(status: 400, message: "请填写银行名称"))
        XCTAssertEqual(invalid, "请填写银行名称")
    }

    // MARK: - 诊断信息

    func testCurrentDiagnosticsAreFilledIn() {
        let current = SubmissionDiagnostics.current()
        XCTAssertTrue(current.appVersion.contains("("), "应当是 \"版本 (构建号)\" 的形式")
        XCTAssertTrue(current.osVersion.contains(UIDevice.current.systemVersion))
        XCTAssertFalse(current.deviceModel.isEmpty)
        XCTAssertNotEqual(current.deviceModel, "arm64", "模拟器上不该拿到 Mac 的架构名")
        XCTAssertFalse(current.language.isEmpty)
    }
}
