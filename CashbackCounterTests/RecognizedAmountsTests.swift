import XCTest
@testable import CashbackCounter

/// 截图 / 短信识别结果 → 原币金额（消费地）+ 入账金额（卡币种）
@MainActor
final class RecognizedAmountsTests: XCTestCase {

    /// 实测的云闪付截图 OCR 原文（卡号已脱敏）：入账 -¥7.33，原币 HK$8.60，外加两条汇率行
    private let unionPayText = """
        15:11 564
        银联交易详情
        MT THE KOWLOON MOTORS BUS CO
        （1933） LTD
        -¥7.33
        （HK$8.60）
        银联汇率 1HK$=0.8524762元
        （本单减免0.03元）
        基础汇率 1HK$=0.8558998元
        卡号 农业银行银联信用卡［1234］
        交易时间 2026-09-19 16:02:38
        订单金额 HK$8.60
        交易渠道 云闪付APP
        交易类别 消费
        分类 行车交通-汽车客运
        受理网络 银联
        点击展开更多
        在此商户交易
        去还款
        """

    private let mainlandCard = StubCard(issueRegion: .cn)

    // MARK: - 同屏两种币种

    /// 回归：模型按指令取了首个金额 ¥7.33，以前整笔被记成「中国大陆 CNY 7.33」
    func testUnionPayScreenshotKeepsOriginalHKDAndActualCNYBilling() async {
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: 7.33, currency: "CNY", rawText: unionPayText, card: mainlandCard, rates: failIfCalled
        )
        XCTAssertEqual(amounts, RecognizedAmounts(amount: 8.60, location: .hk, billingAmount: 7.33, billingRegion: .cn))
    }

    func testModelPickedOriginalAmountFirst() async {
        let text = "交易金额 HKD 8.60\n入账金额 人民币 7.33"
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: 8.60, currency: "HKD", rawText: text, card: mainlandCard, rates: failIfCalled
        )
        XCTAssertEqual(amounts, RecognizedAmounts(amount: 8.60, location: .hk, billingAmount: 7.33, billingRegion: .cn))
    }

    func testWithoutCardFirstAmountIsBilling() async {
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: 7.33, currency: "CNY", rawText: unionPayText, card: nil, rates: failIfCalled
        )
        XCTAssertEqual(amounts, RecognizedAmounts(amount: 8.60, location: .hk, billingAmount: 7.33, billingRegion: .cn))
    }

    func testDualCurrencyCardBilledInSpendCurrencyNeedsNoConversion() async {
        // 港卡开了人民币副币（港式：内地消费按人民币入账），屏幕上的港币只是参考折算
        let card = StubCard(issueRegion: .hk, billing: [.cn: .cn])
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: 7.33, currency: "CNY", rawText: "¥7.33\n约 HK$8.00", card: card, rates: failIfCalled
        )
        XCTAssertEqual(amounts, RecognizedAmounts(amount: 7.33, location: .cn, billingAmount: 7.33, billingRegion: .cn))
    }

    func testSameNumberInTwoCurrenciesIsNotAConversion() async {
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: 8.60, currency: "CNY", rawText: "¥8.60\nHK$8.60", card: mainlandCard, rates: failIfCalled
        )
        XCTAssertEqual(amounts, RecognizedAmounts(amount: 8.60, location: .cn, billingAmount: 8.60, billingRegion: .cn))
    }

    // MARK: - 云端模型标出的原币 / 入账两侧

    func testCloudModelLabelsAreUsedDirectly() async {
        // 两种外币同屏时文本匹配有歧义、放弃；模型的标注照样能用
        let conversion = CurrencyConversion(original: CurrencyAmount(amount: 8.60, region: .hk),
                                            billing: CurrencyAmount(amount: 7.33, region: .cn))
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: 7.33, currency: "CNY", rawText: "HK$8.60\nUS$1.10", card: nil,
            conversion: conversion, rates: failIfCalled
        )
        XCTAssertEqual(amounts, RecognizedAmounts(amount: 8.60, location: .hk, billingAmount: 7.33, billingRegion: .cn))
    }

    func testCloudModelSwappedLabelsAreCorrectedByCard() async {
        // 模型把两侧标反了：大陆单币卡只会按人民币入账，人民币那侧才是入账
        let conversion = CurrencyConversion(original: CurrencyAmount(amount: 7.33, region: .cn),
                                            billing: CurrencyAmount(amount: 8.60, region: .hk))
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: 7.33, currency: "CNY", rawText: "", card: mainlandCard,
            conversion: conversion, rates: failIfCalled
        )
        XCTAssertEqual(amounts, RecognizedAmounts(amount: 8.60, location: .hk, billingAmount: 7.33, billingRegion: .cn))
    }

    func testCloudModelLabelledOnlyOneSide() async {
        let originalOnly = await RecognizedAmounts.resolve(
            totalAmount: 7.33, currency: "CNY", rawText: "", card: mainlandCard,
            conversion: CurrencyConversion(original: CurrencyAmount(amount: 8.60, region: .hk)), rates: failIfCalled
        )
        XCTAssertEqual(originalOnly, RecognizedAmounts(amount: 8.60, location: .hk, billingAmount: 7.33, billingRegion: .cn))

        let billingOnly = await RecognizedAmounts.resolve(
            totalAmount: 8.60, currency: "HKD", rawText: "", card: mainlandCard,
            conversion: CurrencyConversion(billing: CurrencyAmount(amount: 7.33, region: .cn)), rates: failIfCalled
        )
        XCTAssertEqual(billingOnly, RecognizedAmounts(amount: 8.60, location: .hk, billingAmount: 7.33, billingRegion: .cn))
    }

    func testCloudModelSameCurrencyLabelsFallBackToText() async {
        // 模型两侧都写成人民币（等于没分）：退回从 OCR 文本里找另一种币种
        let conversion = CurrencyConversion(original: CurrencyAmount(amount: 7.33, region: .cn),
                                            billing: CurrencyAmount(amount: 7.33, region: .cn))
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: 7.33, currency: "CNY", rawText: unionPayText, card: mainlandCard,
            conversion: conversion, rates: failIfCalled
        )
        XCTAssertEqual(amounts, RecognizedAmounts(amount: 8.60, location: .hk, billingAmount: 7.33, billingRegion: .cn))
    }

    func testConversionFromCloudSchemaCleansAndValidatesSides() {
        var content = CloudPaymentMetadata()
        content.originalAmount = 8.60
        content.originalCurrency = "“HKD”"     // 云端偶发全角引号残渣
        content.billingAmount = -7.33           // 「-¥7.33」带出来的负号
        content.billingCurrency = "CNY"
        XCTAssertEqual(
            ReceiptParser.conversion(from: content),
            CurrencyConversion(original: CurrencyAmount(amount: 8.60, region: .hk),
                               billing: CurrencyAmount(amount: 7.33, region: .cn))
        )

        var singleCurrency = CloudPaymentMetadata()
        singleCurrency.totalAmount = 25
        singleCurrency.currency = "CNY"
        XCTAssertNil(ReceiptParser.conversion(from: singleCurrency))

        var unsupported = CloudPaymentMetadata()
        unsupported.originalAmount = 5
        unsupported.originalCurrency = "SGD"
        XCTAssertNil(ReceiptParser.conversion(from: unsupported), "认不出的币种当没标")
    }

    func testLocalModelYenGuessOnUnionPayScreenIsCorrected() {
        // 本地模型见 ¥ 爱答 JPY；同屏的 HK$ 不能挡住纠偏，否则会拆成「HK$8.60 → 入账 JP¥7.33」
        var metadata = ReceiptMetadata()
        metadata.currency = "JPY"
        XCTAssertEqual(ReceiptParser.correctingLocalYenGuess(metadata, text: unionPayText).currency, "CNY")
    }

    // MARK: - 只有一种币种

    func testForeignSpendWithoutBillingAmountIsConvertedAtTodaysRate() async {
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: 10780, currency: "JPY", rawText: "交易金额 ¥10,780\nコーナン", card: mainlandCard,
            rates: { base in base == "JPY" ? ["CNY": 0.048] : [:] }
        )
        XCTAssertEqual(amounts.amount, 10780)
        XCTAssertEqual(amounts.location, .jp)
        XCTAssertEqual(amounts.billingRegion, .cn)
        XCTAssertEqual(amounts.billingAmount, 517.44, accuracy: 0.001)
        XCTAssertTrue(amounts.isBillingEstimated)
    }

    func testWithoutRatesBillsInOriginalCurrency() async {
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: 10780, currency: "JPY", rawText: "", card: mainlandCard, rates: { _ in [:] }
        )
        XCTAssertEqual(amounts, RecognizedAmounts(amount: 10780, location: .jp, billingAmount: 10780, billingRegion: .jp))
    }

    func testDomesticSpendNeedsNoConversion() async {
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: -25, currency: "CNY", rawText: "支付成功\n-¥25.00", card: mainlandCard, rates: failIfCalled
        )
        XCTAssertEqual(amounts, RecognizedAmounts(amount: 25, location: .cn, billingAmount: 25, billingRegion: .cn))
    }

    func testNoCurrencyAnywhereFallsBackToCardHomeRegion() async {
        let amounts = await RecognizedAmounts.resolve(
            totalAmount: 50, currency: nil, rawText: "KMB 50", card: StubCard(issueRegion: .hk), rates: failIfCalled
        )
        XCTAssertEqual(amounts, RecognizedAmounts(amount: 50, location: .hk, billingAmount: 50, billingRegion: .hk))
    }

    // MARK: - otherCurrencyAmount

    func testOtherCurrencyAmount_SkipsExchangeRates() {
        XCTAssertEqual(OCRService.otherCurrencyAmount(in: unionPayText, excluding: .cn), CurrencyAmount(amount: 8.60, region: .hk))
        XCTAssertNil(OCRService.otherCurrencyAmount(in: "银联汇率 1HK$=0.8524762元", excluding: .cn))
        XCTAssertNil(OCRService.otherCurrencyAmount(in: "1 HKD = 0.8525 CNY", excluding: .cn), "没写「汇率」的等式也不算")
        XCTAssertNil(OCRService.otherCurrencyAmount(in: "Exchange rate HKD 1.0000", excluding: .cn))
    }

    func testOtherCurrencyAmount_MarkerBeforeOrAfter() {
        XCTAssertEqual(OCRService.otherCurrencyAmount(in: "消费 10,780日元", excluding: .cn), CurrencyAmount(amount: 10780, region: .jp))
        XCTAssertEqual(OCRService.otherCurrencyAmount(in: "8.60 HKD", excluding: .cn), CurrencyAmount(amount: 8.60, region: .hk))
        XCTAssertEqual(OCRService.otherCurrencyAmount(in: "港币：8.60", excluding: .cn), CurrencyAmount(amount: 8.60, region: .hk))
        XCTAssertEqual(OCRService.otherCurrencyAmount(in: "折合人民币7.33元", excluding: .hk), CurrencyAmount(amount: 7.33, region: .cn))
    }

    func testOtherCurrencyAmount_IgnoresExcludedCurrencyAndBareSymbols() {
        XCTAssertNil(OCRService.otherCurrencyAmount(in: "CNY 7.33\n¥7.33\n$8.60", excluding: .cn), "裸 ¥ / $ 不算明确币种")
        XCTAssertNil(OCRService.otherCurrencyAmount(in: "MT THE KOWLOON MOTORS BUS CO", excluding: .cn), "MOTORS 不是 MOP")
    }

    func testOtherCurrencyAmount_AmbiguityAndRepetition() {
        XCTAssertNil(OCRService.otherCurrencyAmount(in: "HK$8.60\nUS$1.10", excluding: .cn), "两种外币有歧义")
        XCTAssertEqual(
            OCRService.otherCurrencyAmount(in: "HK$1.00\nHK$8.60\n订单金额 HK$8.60", excluding: .cn),
            CurrencyAmount(amount: 8.60, region: .hk)
        )
    }

    // MARK: - Helpers

    private func failIfCalled(_ base: String) async -> [String: Double] {
        XCTFail("屏幕上已有入账金额或币种相同，不该再查汇率（base: \(base)）")
        return [:]
    }
}

private struct StubCard: CardBillingRules {
    var issueRegion: Region
    /// 双币卡：特定消费地的入账币种；没列出的按发卡地区入账
    var billing: [Region: Region] = [:]

    func billingRegion(for location: Region) -> Region {
        billing[location] ?? issueRegion
    }
}
