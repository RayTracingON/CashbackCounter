import XCTest
import SwiftData
@testable import CashbackCounter

private typealias Category = CashbackCounter.Category

final class DualCurrencyCardTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema([CreditCard.self, Transaction.self, Point.self, PointAdjustment.self, Income.self])
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        let config = ModelConfiguration(url: url, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeCard(
        defaultRate: Double = 0.01,
        issueRegion: Region = .hk,
        foreignCurrencyRate: Double? = nil,
        localBaseCap: Double = 0,
        foreignBaseCap: Double = 0,
        capPeriod: CapPeriod = .yearly,
        secondaryRegion: Region? = nil,
        dualCurrencyMode: DualCurrencyMode = .secondaryAsLocal,
        secondaryRate: Double? = nil
    ) -> CreditCard {
        let card = CreditCard(
            bankName: "TestBank",
            type: "TestCard",
            endNum: "1234",
            colorHexes: ["FF0000"],
            defaultRate: defaultRate,
            specialRates: [:],
            issueRegion: issueRegion,
            foreignCurrencyRate: foreignCurrencyRate,
            localBaseCap: localBaseCap,
            foreignBaseCap: foreignBaseCap,
            capPeriod: capPeriod,
            rewardType: .cashback,
            secondaryRegion: secondaryRegion,
            dualCurrencyMode: dualCurrencyMode,
            secondaryRate: secondaryRate
        )
        context.insert(card)
        return card
    }

    @discardableResult
    private func makeTransaction(card: CreditCard, amount: Double, location: Region, date: Date = Date()) -> Transaction {
        let tx = Transaction(
            merchant: "Test Merchant",
            category: .other,
            location: location,
            amount: amount,
            date: date,
            card: card
        )
        context.insert(tx)
        if card.transactions == nil {
            card.transactions = [tx]
        } else {
            card.transactions?.append(tx)
        }
        return tx
    }

    // MARK: - 1. 港式双币卡：副币消费 1:1 并入本币上限

    func testHKDualCard_BillingRegionResolution() {
        let card = makeCard(issueRegion: .hk, secondaryRegion: .cn, dualCurrencyMode: .secondaryAsLocal)

        XCTAssertEqual(card.billingRegion(for: .hk), .hk, "本地消费入 HKD 账")
        XCTAssertEqual(card.billingRegion(for: .cn), .cn, "内地消费入 CNY 账")
        XCTAssertEqual(card.billingRegion(for: .us), .hk, "其他境外消费入 HKD 账")
        XCTAssertEqual(card.rewardTrack(for: .cn), .local, "CNY 消费并入本币轨道")
        XCTAssertEqual(card.rewardTrack(for: .us), .foreign)
    }

    func testHKDualCard_MergedCapOneToOne() {
        // localBaseCap = 100 (HKD 计价)，费率 1%
        let card = makeCard(
            defaultRate: 0.01,
            issueRegion: .hk,
            localBaseCap: 100,
            secondaryRegion: .cn,
            dualCurrencyMode: .secondaryAsLocal
        )
        let now = Date()

        // HKD 历史消费 6000 → 已用 60；CNY 历史消费 3000 → 按 1:1 再用 30，共 90
        makeTransaction(card: card, amount: 6000, location: .hk, date: now)
        makeTransaction(card: card, amount: 3000, location: .cn, date: now)

        // 新 CNY 消费 2000 → 理论 20，剩余 10 → 封顶 10
        let cashback = card.calculateCappedCashback(
            amount: 2000, category: .other, location: .cn, date: now, paymentMethod: .offline
        )
        XCTAssertEqual(cashback, 10, accuracy: 0.0001, "CNY 消费应按 1:1 计入 HKD 上限后封顶")
    }

    func testHKDualCard_ForeignTrackUnaffectedByMergedUsage() {
        let card = makeCard(
            defaultRate: 0.01,
            issueRegion: .hk,
            foreignCurrencyRate: 0.02,
            localBaseCap: 100,
            foreignBaseCap: 50,
            secondaryRegion: .cn,
            dualCurrencyMode: .secondaryAsLocal
        )
        let now = Date()

        // 本币轨道已接近打满 (60 + 30 = 90/100)
        makeTransaction(card: card, amount: 6000, location: .hk, date: now)
        makeTransaction(card: card, amount: 3000, location: .cn, date: now)

        // 美国消费走外币轨道：1000 * 2% = 20，外币上限 50 未被本币用量占用
        let cashback = card.calculateCappedCashback(
            amount: 1000, category: .other, location: .us, date: now, paymentMethod: .offline
        )
        XCTAssertEqual(cashback, 20, accuracy: 0.0001, "外币轨道不应受本币合并用量影响")
    }

    // MARK: - 2. 陆式双币卡：两币种独立上限

    func testMainlandDualCard_BillingRegionResolution() {
        let card = makeCard(issueRegion: .cn, secondaryRegion: .us, dualCurrencyMode: .secondaryAsForeign)

        XCTAssertEqual(card.billingRegion(for: .cn), .cn, "境内消费入 CNY 账")
        XCTAssertEqual(card.billingRegion(for: .us), .us)
        XCTAssertEqual(card.billingRegion(for: .jp), .us, "所有境外消费一律入 USD 账")
        XCTAssertEqual(card.rewardTrack(for: .jp), .foreign)
    }

    func testMainlandDualCard_SeparateCaps() {
        // 本币上限 50 (CNY)，外币上限 30 (USD)
        let card = makeCard(
            defaultRate: 0.01,
            issueRegion: .cn,
            foreignCurrencyRate: 0.02,
            localBaseCap: 50,
            foreignBaseCap: 30,
            secondaryRegion: .us,
            dualCurrencyMode: .secondaryAsForeign
        )
        let now = Date()

        // 本币历史消费 4000 → 本币轨道已用 40/50
        makeTransaction(card: card, amount: 4000, location: .cn, date: now)

        // 境外 (日本) 消费 1000 → 外币轨道 1000*2% = 20 ≤ 30，不受本币用量影响
        let foreignCashback = card.calculateCappedCashback(
            amount: 1000, category: .other, location: .jp, date: now, paymentMethod: .offline
        )
        XCTAssertEqual(foreignCashback, 20, accuracy: 0.0001, "外币上限独立，不受本币用量影响")

        // 外币历史再消费 1000 (又用 20，外币共 40 > 30 上限的剩余 10)
        makeTransaction(card: card, amount: 1000, location: .jp, date: now)
        let cappedForeign = card.calculateCappedCashback(
            amount: 1000, category: .other, location: .us, date: now, paymentMethod: .offline
        )
        XCTAssertEqual(cappedForeign, 10, accuracy: 0.0001, "外币轨道自身上限应生效")

        // 本币消费 2000 → 理论 20，本币剩余 10 → 封顶 10，不受外币用量影响
        let localCashback = card.calculateCappedCashback(
            amount: 2000, category: .other, location: .cn, date: now, paymentMethod: .offline
        )
        XCTAssertEqual(localCashback, 10, accuracy: 0.0001, "本币上限独立，不受外币用量影响")
    }

    // MARK: - 3. secondaryRate 覆盖

    func testSecondaryRateOverride() {
        let card = makeCard(
            defaultRate: 0.01,
            issueRegion: .hk,
            secondaryRegion: .cn,
            dualCurrencyMode: .secondaryAsLocal,
            secondaryRate: 0.005
        )

        XCTAssertEqual(card.baseRate(forLocation: .cn), 0.005, accuracy: 0.000001, "副币消费用 secondaryRate")
        XCTAssertEqual(card.baseRate(forLocation: .hk), 0.01, accuracy: 0.000001, "本币消费仍用 defaultRate")
        XCTAssertEqual(card.getRate(for: .other, location: .cn, payment: .offline), 0.005, accuracy: 0.000001)

        // 上限用量也按覆盖后的费率累计
        let now = Date()
        makeTransaction(card: card, amount: 2000, location: .cn, date: now) // 用 2000*0.005 = 10
        let cardWithCap = card
        cardWithCap.localBaseCap = 15
        let cashback = cardWithCap.calculateCappedCashback(
            amount: 2000, category: .other, location: .cn, date: now, paymentMethod: .offline
        )
        XCTAssertEqual(cashback, 5, accuracy: 0.0001, "历史用量按 secondaryRate 累计后剩余 5")
    }

    // MARK: - 4. 单币卡回归：行为与旧逻辑一致

    func testSingleCurrencyCard_Regression() {
        let card = makeCard(
            defaultRate: 0.01,
            issueRegion: .hk,
            foreignCurrencyRate: 0.02
        )

        XCTAssertFalse(card.isDualCurrency)
        XCTAssertEqual(card.billingRegion(for: .hk), .hk)
        XCTAssertEqual(card.billingRegion(for: .cn), .hk, "单币卡所有消费入主币账")
        XCTAssertEqual(card.rewardTrack(for: .hk), .local)
        XCTAssertEqual(card.rewardTrack(for: .cn), .foreign, "单币卡异地即外币，与旧逻辑一致")
        XCTAssertEqual(card.baseRate(forLocation: .hk), 0.01, accuracy: 0.000001)
        XCTAssertEqual(card.baseRate(forLocation: .us), 0.02, accuracy: 0.000001)
    }

    func testSingleCurrencyCard_SecondarySameAsIssueIsIgnored() {
        // secondaryRegion == issueRegion 视为单币卡
        let card = makeCard(issueRegion: .hk, secondaryRegion: .hk)
        XCTAssertFalse(card.isDualCurrency)
        XCTAssertEqual(card.rewardTrack(for: .cn), .foreign)
    }

    // MARK: - 5. Transaction 入账币种

    func testTransaction_AutoBillingCurrencyCode() {
        let card = makeCard(issueRegion: .hk, secondaryRegion: .cn, dualCurrencyMode: .secondaryAsLocal)

        let cnTx = makeTransaction(card: card, amount: 100, location: .cn)
        XCTAssertEqual(cnTx.billingCurrencyCode, "CNY", "内地消费自动判定入 CNY 账")
        XCTAssertEqual(cnTx.resolvedBillingCurrencyCode, "CNY")

        let usTx = makeTransaction(card: card, amount: 100, location: .us)
        XCTAssertEqual(usTx.billingCurrencyCode, "HKD", "其他境外消费入 HKD 账")
    }

    func testTransaction_LegacyNilCodeHeuristic() {
        let card = makeCard(issueRegion: .hk)

        // 旧数据：billingAmount == amount 且异地 → 按消费地币种
        let legacyTx = makeTransaction(card: card, amount: 100, location: .us)
        legacyTx.billingCurrencyCode = nil
        XCTAssertEqual(legacyTx.resolvedBillingCurrencyCode, "USD", "未换汇的旧数据按消费地币种")

        // 旧数据：已换汇 (billingAmount != amount) → 按卡片入账规则
        let convertedTx = Transaction(
            merchant: "Test", category: .other, location: .us,
            amount: 100, date: Date(), card: card, billingAmount: 780
        )
        context.insert(convertedTx)
        convertedTx.billingCurrencyCode = nil
        XCTAssertEqual(convertedTx.resolvedBillingCurrencyCode, "HKD", "已换汇的旧数据按卡片规则")
    }

    func testRegion_FromCurrencyCode() {
        XCTAssertEqual(Region.from(currencyCode: "CNY"), .cn)
        XCTAssertEqual(Region.from(currencyCode: "hkd"), .hk)
        XCTAssertNil(Region.from(currencyCode: "XXX"))
    }

    // MARK: - 6. CSV 导入导出

    func testCardCSV_RoundTripDualCurrencyFields() throws {
        let card = makeCard(
            defaultRate: 0.01,
            issueRegion: .cn,
            foreignCurrencyRate: 0.02,
            secondaryRegion: .us,
            dualCurrencyMode: .secondaryAsForeign,
            secondaryRate: 0.015
        )

        let csv = CardCSVHelper.generateCSV(from: [card])
        context.delete(card)
        try context.save()

        try CardCSVHelper.parseCSV(content: csv, into: context)
        let imported = try context.fetch(FetchDescriptor<CreditCard>())
        XCTAssertEqual(imported.count, 1)

        let restored = try XCTUnwrap(imported.first)
        XCTAssertEqual(restored.secondaryRegion, .us)
        XCTAssertEqual(restored.dualCurrencyMode, .secondaryAsForeign)
        XCTAssertEqual(try XCTUnwrap(restored.secondaryRate), 0.015, accuracy: 0.000001)
    }

    func testCardCSV_LegacyWithoutDualColumns() throws {
        // 旧版 CSV (无双币列) 导入后应为单币卡
        let legacyHeader = "银行名称,卡种名称,尾号,颜色1(Hex),颜色2(Hex),地区(Code),本币返现率(%),外币返现率(%),本币上限,外币上限,餐饮加成(%),超市加成(%),出行加成(%),数码加成(%),其他加成(%),餐饮上限,超市上限,出行上限,数码上限,其他上限,上限周期(monthly/yearly),还款日"
        let legacyRow = "OldBank,OldCard,9999,FF0000,000000,香港,1.00,2.00,,,,,,,,,,,,,yearly,0"
        try CardCSVHelper.parseCSV(content: legacyHeader + "\n" + legacyRow, into: context)

        let imported = try context.fetch(FetchDescriptor<CreditCard>())
        let restored = try XCTUnwrap(imported.first { $0.bankName == "OldBank" })
        XCTAssertNil(restored.secondaryRegion)
        XCTAssertFalse(restored.isDualCurrency)
    }

    func testTransactionCSV_RoundTripBillingCurrency() throws {
        let card = makeCard(issueRegion: .hk, secondaryRegion: .cn, dualCurrencyMode: .secondaryAsLocal)
        let tx = makeTransaction(card: card, amount: 100, location: .cn)
        XCTAssertEqual(tx.billingCurrencyCode, "CNY")

        let csv = [tx].generateCSV()
        XCTAssertTrue(csv.contains("入账币种"))
        XCTAssertTrue(csv.contains(",CNY\n"))

        // 删除原交易再导入，避免命中去重逻辑
        context.delete(tx)
        try context.save()

        let imported = try CSVHelper.parseTransactionCSV(content: csv, context: context, allCards: [card])
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.billingCurrencyCode, "CNY")
    }

    func testTransactionCSV_LegacyWithoutCurrencyColumn() throws {
        let card = makeCard(issueRegion: .hk)

        // 旧版 CSV：无入账币种列，且 billing == amount (未换汇的美国消费)
        let legacyHeader = "交易时间,商户名称,消费类别,消费金额(原币),入账金额(本币),返现金额(本币),支付卡片,卡片尾号,消费地区,支付方式,积分数"
        let legacyRow = "2026-01-01,\"Shop\",其他,100.00,100.00,1.00,\"TestBank TestCard\",1234,美国,offline,0"
        let imported = try CSVHelper.parseTransactionCSV(content: legacyHeader + "\n" + legacyRow, context: context, allCards: [card])

        let tx = try XCTUnwrap(imported.first)
        XCTAssertNil(tx.billingCurrencyCode, "旧版 CSV 导入不应写死入账币种")
        XCTAssertEqual(tx.resolvedBillingCurrencyCode, "USD", "未换汇的旧数据应按消费地币种解析")
    }

    // MARK: - 7. 上限进度条币种

    func testCapProgress_ForeignTrackCurrencySymbol() {
        // 陆式双币卡：外币轨道以副币种 (USD) 计价
        let mainlandCard = makeCard(
            defaultRate: 0.01,
            issueRegion: .cn,
            foreignCurrencyRate: 0.02,
            foreignBaseCap: 30,
            secondaryRegion: .us,
            dualCurrencyMode: .secondaryAsForeign
        )
        let items = mainlandCard.cashbackCapProgress()
        let foreignItem = items.first { $0.id == "base_foreign" }
        XCTAssertEqual(foreignItem?.currencySymbolOverride, Region.us.currencySymbol)

        // 港式双币卡：外币轨道仍以主币 (HKD) 计价，不覆盖
        let hkCard = makeCard(
            defaultRate: 0.01,
            issueRegion: .hk,
            foreignCurrencyRate: 0.02,
            foreignBaseCap: 30,
            secondaryRegion: .cn,
            dualCurrencyMode: .secondaryAsLocal
        )
        let hkForeignItem = hkCard.cashbackCapProgress().first { $0.id == "base_foreign" }
        XCTAssertNil(hkForeignItem?.currencySymbolOverride)
    }

    func testCapProgress_MergedLocalTrackIncludesSecondarySpend() {
        // 港式卡本币进度应包含副币消费的 1:1 用量
        let card = makeCard(
            defaultRate: 0.01,
            issueRegion: .hk,
            localBaseCap: 100,
            secondaryRegion: .cn,
            dualCurrencyMode: .secondaryAsLocal
        )
        let now = Date()
        makeTransaction(card: card, amount: 6000, location: .hk, date: now)
        makeTransaction(card: card, amount: 3000, location: .cn, date: now)

        let localItem = card.cashbackCapProgress(asOf: now).first { $0.id == "base_local" }
        XCTAssertEqual(localItem?.used ?? 0, 90, accuracy: 0.0001, "60 (HKD) + 30 (CNY 按 1:1) = 90")
    }
}
