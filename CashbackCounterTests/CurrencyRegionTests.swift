import XCTest
@testable import CashbackCounter

/// 交易地区判定：模型币种优先、全文关键词兜底、本地模型 ¥ 纠偏
@MainActor
final class CurrencyRegionTests: XCTestCase {

    // MARK: - resolveRegion

    /// 回归：中文界面截图里的「交易 / 金额」曾推翻模型识别出的 JPY，把日本消费记成中国大陆
    func testResolveRegion_ModelCurrencyBeatsChineseUIKeywords() {
        let rawText = "交易详情\n交易金额 ¥10,780\nKOHNAN SHOJI CO.,LTD\n交易时间 2026-09-21"
        XCTAssertEqual(OCRService.simpleInferRegion(from: rawText), .cn, "前提：全文关键词只能看出这是简体界面")
        XCTAssertEqual(OCRService.resolveRegion(currency: "JPY", rawText: rawText), .jp)
        XCTAssertEqual(OCRService.resolveRegion(currency: "USD", rawText: rawText), .us)
    }

    func testResolveRegion_FallsBackToTextWithoutUsableModelCurrency() {
        XCTAssertEqual(OCRService.resolveRegion(currency: nil, rawText: "Total HK$ 50"), .hk)
        // 裸 ¥ 中日共用，交给全文判断
        XCTAssertEqual(OCRService.resolveRegion(currency: "¥", rawText: "合計 1,100円"), .jp)
        XCTAssertNil(OCRService.resolveRegion(currency: nil, rawText: "Thank you"))
    }

    // MARK: - Region.from(currencyText:)

    func testRegionFromCurrencyText_CodesAndAliases() {
        let cases: [(String, Region)] = [
            ("JPY", .jp), (" jpy ", .jp), ("JP¥", .jp), ("円", .jp), ("日元", .jp),
            ("CNY", .cn), ("RMB", .cn), ("人民币", .cn), ("CNY (RMB)", .cn),
            ("HK$", .hk), ("港币", .hk), ("NT$", .tw), ("US$", .us),
            ("£", .uk), ("€", .other), ("MOP$", .mo), ("NZD", .nz)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(Region.from(currencyText: text), expected, text)
        }
    }

    func testRegionFromCurrencyText_AmbiguousOrUnknownIsNil() {
        // 澳元是 AUD，不能被认成澳门元
        for text in ["¥", "$", "JPY/CNY", "SGD", "澳元", ""] {
            XCTAssertNil(Region.from(currencyText: text), text)
        }
    }

    // MARK: - simpleInferRegion

    func testSimpleInferRegion_NoSubstringFalsePositives() {
        XCTAssertEqual(OCRService.simpleInferRegion(from: "IKEBUKURO\n合計 ¥1,100"), .jp, "IKEBUKURO 里的 UK")
        XCTAssertEqual(OCRService.simpleInferRegion(from: "FUKUOKA 料金 500"), .jp, "FUKUOKA 里的 UK")
        XCTAssertEqual(OCRService.simpleInferRegion(from: "MUSASHINO\n料金 500"), .jp, "MUSASHINO 里的 USA")
        XCTAssertNil(OCRService.simpleInferRegion(from: "AMATEUR RADIO SUZUKI"), "AMATEUR 里的 EUR、SUZUKI 里的 UK")
        XCTAssertEqual(OCRService.simpleInferRegion(from: "JPY10780"), .jp, "紧贴数字照样算整词")
    }

    func testSimpleInferRegion_TraditionalChineseTotalIsNotJapan() {
        XCTAssertEqual(OCRService.simpleInferRegion(from: "HONG KONG\n合計 $120"), .hk)
        XCTAssertEqual(OCRService.simpleInferRegion(from: "TAIPEI\n合計 350"), .tw)
    }

    func testSimpleInferRegion_KanaBeatsChineseUIWords() {
        XCTAssertEqual(OCRService.simpleInferRegion(from: "交易金额 ¥10,780\nコーナン"), .jp)
        XCTAssertEqual(OCRService.simpleInferRegion(from: "交易金额 ¥10,780\nｺｰﾅﾝ"), .jp, "半角片假名")
        // 中点 ・ 和长音 ー 中文里也会出现，不算假名
        XCTAssertEqual(OCRService.simpleInferRegion(from: "交易金额 ¥25\n瑞幸咖啡・外卖ー"), .cn)
    }

    // MARK: - 本地模型 ¥ 纠偏

    func testLocalYenCorrection_FixesJPYOnMainlandScreen() {
        let alipay = "支付成功\n¥25.00\n瑞幸咖啡\n交易时间 2026-10-05"
        XCTAssertEqual(ReceiptParser.correctingLocalYenGuess(metadata(currency: "JPY"), text: alipay).currency, "CNY")
    }

    func testLocalYenCorrection_KeepsJPYWhenJapanIsEvident() {
        let texts = [
            "交易金额 ¥10,780\nコーナン",                    // 日本商户名（假名）
            "交易金额 10,780 日元\n入账金额 520.00 人民币",    // 同屏多币种：外币消费 + 人民币入账
            "Total ¥1,100"                                    // 没有任何中国大陆迹象
        ]
        for text in texts {
            XCTAssertEqual(ReceiptParser.correctingLocalYenGuess(metadata(currency: "JPY"), text: text).currency, "JPY", text)
        }
    }

    func testLocalYenCorrection_LeavesOtherCurrenciesAlone() {
        let text = "交易金额 $12.50"
        XCTAssertEqual(ReceiptParser.correctingLocalYenGuess(metadata(currency: "USD"), text: text).currency, "USD")
        XCTAssertNil(ReceiptParser.correctingLocalYenGuess(metadata(currency: nil), text: text).currency)
    }

    private func metadata(currency: String?) -> ReceiptMetadata {
        var metadata = ReceiptMetadata()
        metadata.currency = currency
        return metadata
    }
}
