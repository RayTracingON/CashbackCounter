import XCTest
import SwiftData
@testable import CashbackCounter

private typealias Category = CashbackCounter.Category
private typealias Transaction = CashbackCounter.Transaction

/// 返现正确性（审查报告第二组）：
///
///   · 上限按时间顺序消耗，周期内任何增删改之后整个周期重算（C1）
///   · 封顶是增量：退款只在额度真的回落到上限以下时才扣回（C2）
///   · 积分卡预览的"已封顶"只在真封顶时亮（H1）
///   · 积分卡的奖励按发卡币种计价（H2）
///   · Plaid 交易地区按结算币种解析（二、8）
///   · CSV：积分计划、来源 / 去重ID、类别 rawValue 都要能导回来（四、1-3）
@MainActor
final class RewardEngineTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema([
            Transaction.self, CreditCard.self, Income.self, Point.self, PointAdjustment.self,
            LinkedBankAccount.self
        ])
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(url: url, cloudKitDatabase: .none)])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    private func makeCard(defaultRate: Double = 0.01,
                          localBaseCap: Double = 0,
                          capPeriod: CapPeriod = .yearly,
                          specialRates: [Category: Double] = [:],
                          categoryCaps: [Category: Double] = [:],
                          issueRegion: Region = .hk,
                          foreignCurrencyRate: Double? = nil,
                          rewardType: RewardType = .cashback,
                          pointProgram: Point? = nil,
                          secondaryRegion: Region? = nil,
                          dualCurrencyMode: DualCurrencyMode = .secondaryAsLocal) -> CreditCard {
        let card = CreditCard(
            bankName: "Bank", type: "Card", endNum: "0001", colorHexes: ["FF0000"],
            defaultRate: defaultRate, specialRates: specialRates, issueRegion: issueRegion,
            foreignCurrencyRate: foreignCurrencyRate,
            localBaseCap: localBaseCap, categoryCaps: categoryCaps, capPeriod: capPeriod,
            rewardType: rewardType, pointProgram: pointProgram,
            secondaryRegion: secondaryRegion, dualCurrencyMode: dualCurrencyMode)
        context.insert(card)
        return card
    }

    private func day(_ string: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: string)!
    }

    /// 模拟 App 的保存路径：按引擎算初值 → 入库挂卡 → 周期重算
    @discardableResult
    private func add(card: CreditCard, amount: Double, date: Date,
                     category: Category = .other, location: Region = .hk,
                     dedupeID: String? = nil, pointValue: Double = 0) -> Transaction {
        let initial = card.calculateCappedCashback(
            amount: amount, category: category, location: location, date: date, paymentMethod: .offline)
        let tx = Transaction(
            merchant: "M", category: category, location: location, amount: amount, date: date,
            card: card, billingAmount: amount, cashbackAmount: initial)
        if let dedupeID { tx.dedupeID = dedupeID }
        context.insert(tx)
        if card.transactions == nil { card.transactions = [tx] } else { card.transactions?.append(tx) }
        card.recalculateRewards(inPeriodOf: date, pointValueInCardCurrency: pointValue)
        return tx
    }

    // MARK: - C2 增量封顶

    func testIncrementFormula() {
        // 无上限：原样
        XCTAssertEqual(CreditCard.cappedIncrement(potential: 7, used: 100, cap: 0), 7)
        // 正常：剩余额度
        XCTAssertEqual(CreditCard.cappedIncrement(potential: 7, used: 5, cap: 10), 5)
        // 已打满：0
        XCTAssertEqual(CreditCard.cappedIncrement(potential: 7, used: 50, cap: 10), 0)
        // 打满后的退款：理论用量 50→40 仍 ≥ 上限，不扣
        XCTAssertEqual(CreditCard.cappedIncrement(potential: -10, used: 50, cap: 10), 0)
        // 退款让用量回落到上限以下：只扣回落的那部分
        XCTAssertEqual(CreditCard.cappedIncrement(potential: -5, used: 12, cap: 10), -3)
        // 未打满时的退款：全额扣
        XCTAssertEqual(CreditCard.cappedIncrement(potential: -2, used: 5, cap: 10), -2)
    }

    func testRefundAfterCapIsNotClawedBackTwice() {
        let card = makeCard(defaultRate: 0.01, localBaseCap: 10)
        let t1 = add(card: card, amount: 5000, date: day("2026-03-01"))   // 理论 50 → 10
        let t2 = add(card: card, amount: -1000, date: day("2026-03-05"))  // 用量 50→40 仍 ≥ 10
        let t3 = add(card: card, amount: 1000, date: day("2026-03-10"))   // 仍封顶
        XCTAssertEqual(t1.cashbackamount, 10, accuracy: 0.0001)
        XCTAssertEqual(t2.cashbackamount, 0, accuracy: 0.0001, "额度早已打满，退款不该扣回")
        XCTAssertEqual(t3.cashbackamount, 0, accuracy: 0.0001)
        XCTAssertEqual(t1.cashbackamount + t2.cashbackamount + t3.cashbackamount, 10, accuracy: 0.0001)
    }

    func testRefundWithoutCapStaysFullyNegative() {
        let card = makeCard(defaultRate: 0.01, specialRates: [.dining: 0.05])
        let refund = add(card: card, amount: -100, date: day("2026-03-05"), category: .dining)
        XCTAssertEqual(refund.cashbackamount, -6, accuracy: 0.0001, "无上限时退款全额回冲（旧行为保持）")
    }

    // MARK: - C1 顺序重算

    func testBackdatedEntryReallocatesCapChronologically() {
        let card = makeCard(defaultRate: 0.01, localBaseCap: 10, capPeriod: .monthly)
        let late = add(card: card, amount: 1000, date: day("2026-03-20"))
        XCTAssertEqual(late.cashbackamount, 10, accuracy: 0.0001)

        let early = add(card: card, amount: 500, date: day("2026-03-05"))
        XCTAssertEqual(early.cashbackamount, 5, accuracy: 0.0001, "补录的早期交易先吃额度")
        XCTAssertEqual(late.cashbackamount, 5, accuracy: 0.0001, "晚的那笔只剩 5")
    }

    func testDeleteRestoresCapToSiblings() async throws {
        let card = makeCard(defaultRate: 0.01, localBaseCap: 10)
        let t1 = add(card: card, amount: 1000, date: day("2026-03-01"))
        let t2 = add(card: card, amount: 1000, date: day("2026-03-02"))
        XCTAssertEqual(t2.cashbackamount, 0, accuracy: 0.0001)
        try context.save()

        await Transaction.deleteRecalculating(t1, in: context)
        XCTAssertEqual(t2.cashbackamount, 10, accuracy: 0.0001, "删掉 t1 后额度应回到 t2")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).count, 1)
    }

    func testRuleChangeRecalculatesHistory() {
        let card = makeCard(defaultRate: 0.01)
        let tx = add(card: card, amount: 1000, date: day("2026-03-01"))
        XCTAssertEqual(tx.cashbackamount, 10, accuracy: 0.0001)

        card.defaultRate = 0.02
        card.recalculateAllRewards(pointValueInCardCurrency: 0)
        XCTAssertEqual(tx.cashbackamount, 20, accuracy: 0.0001, "改费率后历史交易按新规则重算")
    }

    func testPreviewMatchesSavedAllocationOnSameDay() {
        let card = makeCard(defaultRate: 0.01, localBaseCap: 10)
        let existing = add(card: card, amount: 1000, date: day("2026-03-01"), dedupeID: "zzz")
        XCTAssertEqual(existing.cashbackamount, 10, accuracy: 0.0001)

        // 同一天、顺序键更小的候选排在前面，预览应显示它拿到全部额度
        let preview = card.simulateReward(
            amount: 1000, category: .other, location: .hk, date: day("2026-03-01"),
            paymentMethod: .offline, sortKey: "aaa")
        XCTAssertEqual(preview.capped, 10, accuracy: 0.0001)
        XCTAssertFalse(preview.isCapped)

        // 存进去再重算，分配和预览一致
        let saved = add(card: card, amount: 1000, date: day("2026-03-01"), dedupeID: "aaa")
        XCTAssertEqual(saved.cashbackamount, 10, accuracy: 0.0001)
        XCTAssertEqual(existing.cashbackamount, 0, accuracy: 0.0001)

        // 不给顺序键：排在同一天最后，历史先吃额度（旧接口语义）
        let legacy = card.simulateReward(
            amount: 1000, category: .other, location: .hk, date: day("2026-03-01"), paymentMethod: .offline)
        XCTAssertEqual(legacy.capped, 0, accuracy: 0.0001)
        XCTAssertTrue(legacy.isCapped)
    }

    func testPointsCardRefundGivesNegativePoints() {
        let point = Point(bankName: "B", pointName: "P", pointValue: 0.01, valueCurrencyCode: .hk)
        context.insert(point)
        let card = makeCard(defaultRate: 1.0, rewardType: .points, pointProgram: point)
        let buy = add(card: card, amount: 100, date: day("2026-03-01"), pointValue: 0.01)
        let refund = add(card: card, amount: -40, date: day("2026-03-02"), pointValue: 0.01)
        XCTAssertEqual(buy.pointsEarned, 100)
        XCTAssertEqual(refund.pointsEarned, -40, "退款扣回整数积分")
        XCTAssertEqual(refund.cashbackamount, -0.4, accuracy: 0.0001)
    }

    func testPointsAreCountedEvenWhenValueIsUnknown() {
        let result = CreditCard.pointsReward(fromCappedTotal: 125.6, pointValueInCardCurrency: 0)
        XCTAssertEqual(result.points, 125, "估值拿不到不该让积分数归零")
        XCTAssertEqual(result.value, 0)
    }

    // MARK: - H1 积分预览

    func testPointsPreviewIsCappedOnlyWhenActuallyCapped() async throws {
        let point = Point(bankName: "B", pointName: "P", pointValue: 0.01, valueCurrencyCode: .hk)
        context.insert(point)
        let uncapped = makeCard(defaultRate: 1.0, rewardType: .points, pointProgram: point)
        let capped = makeCard(defaultRate: 1.0, localBaseCap: 50, rewardType: .points, pointProgram: point)
        try context.save()

        func preview(for card: CreditCard) async throws -> AddTransactionViewModel.RewardPreview {
            let vm = AddTransactionViewModel()
            vm.amount = "100"
            vm.billingAmountStr = "100"
            vm.location = .hk
            vm.selectedCardIndex = 0
            vm.updateRewardPreview(cards: [card])
            for _ in 0..<40 where vm.rewardPreview == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return try XCTUnwrap(vm.rewardPreview)
        }

        let free = try await preview(for: uncapped)
        XCTAssertEqual(free.points, 100)
        XCTAssertFalse(free.isCapped, "无上限的积分卡不该显示已封顶")

        let limited = try await preview(for: capped)
        XCTAssertEqual(limited.points, 50)
        XCTAssertTrue(limited.isCapped)
    }

    // MARK: - H2 奖励币种

    func testPointsCardRewardCurrencyIsIssueCurrency() {
        let point = Point(bankName: "B", pointName: "P", pointValue: 0.01, valueCurrencyCode: .cn)
        context.insert(point)
        let pointsCard = makeCard(defaultRate: 1.0, issueRegion: .cn, rewardType: .points, pointProgram: point,
                                  secondaryRegion: .us, dualCurrencyMode: .secondaryAsForeign)
        let pointsTx = Transaction(merchant: "M", category: .other, location: .us, amount: 100, date: Date(), card: pointsCard)
        context.insert(pointsTx)
        XCTAssertEqual(pointsTx.billingCurrencyCode, "USD", "境外消费入账副币 USD")
        XCTAssertEqual(pointsTx.rewardCurrencyCode, "CNY", "积分价值按发卡币种估，统计要按 CNY 换算")

        let cashCard = makeCard(defaultRate: 0.01, issueRegion: .cn,
                                secondaryRegion: .us, dualCurrencyMode: .secondaryAsForeign)
        let cashTx = Transaction(merchant: "M", category: .other, location: .us, amount: 100, date: Date(), card: cashCard)
        context.insert(cashTx)
        XCTAssertEqual(cashTx.rewardCurrencyCode, "USD", "返现卡的返现随入账币种")
    }

    // MARK: - 二、8 Plaid 地区

    func testPlaidLocationFollowsSettlementCurrency() {
        let ukCard = makeCard(issueRegion: .uk)
        func dto(_ currency: String?) -> PlaidTransactionDTO {
            PlaidTransactionDTO(accountId: "a", accountName: nil, accountMask: nil, date: "2026-07-01",
                                name: "Tesco", merchantName: nil, amount: 10, currency: currency, pending: false,
                                category: nil, categoryDetailed: nil, paymentChannel: nil)
        }
        XCTAssertEqual(PlaidSyncService.location(for: dto("GBP"), card: ukCard), .uk)
        XCTAssertEqual(PlaidSyncService.location(for: dto("USD"), card: ukCard), .us)
        XCTAssertEqual(PlaidSyncService.location(for: dto("XXX"), card: ukCard), .uk, "认不出的币种按发卡地")
        XCTAssertEqual(PlaidSyncService.location(for: dto(nil), card: ukCard), .uk)
    }

    func testPlaidBackfillRecalculatesLaterRows() async throws {
        let card = makeCard(defaultRate: 0.01, localBaseCap: 10, capPeriod: .monthly, issueRegion: .us)
        let account = LinkedBankAccount(itemId: "i", accountId: "acct", institutionName: "Chase",
                                        accountName: "Freedom", mask: "0001", card: card, syncEnabled: true)
        context.insert(account)
        try context.save()
        func dto(_ date: String, _ amount: Double) -> PlaidTransactionDTO {
            PlaidTransactionDTO(accountId: "acct", accountName: nil, accountMask: nil, date: date,
                                name: "Shop", merchantName: "Shop", amount: amount, currency: "USD", pending: false,
                                category: "GENERAL_MERCHANDISE", categoryDetailed: nil, paymentChannel: "in store")
        }
        _ = await PlaidSyncService.shared.process([dto("2026-07-20", 1000)], accounts: [account], pointValues: [:], context: context)
        try context.save()
        _ = await PlaidSyncService.shared.process([dto("2026-07-05", 500)], accounts: [account], pointValues: [:], context: context)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<Transaction>()).sorted { $0.date < $1.date }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].cashbackamount, 5, accuracy: 0.0001, "后同步进来的早期交易先吃额度")
        XCTAssertEqual(rows[1].cashbackamount, 5, accuracy: 0.0001, "晚的那笔被重算")
    }

    // MARK: - 四、1 卡片 CSV 积分计划

    func testCardCSVRoundTripKeepsPointProgram() throws {
        let point = Point(bankName: "HSBC HK", pointName: "RC", pointValue: 1.25, valueCurrencyCode: .hk)
        context.insert(point)
        let card = makeCard(defaultRate: 1.0, rewardType: .points, pointProgram: point,
                            secondaryRegion: .cn, dualCurrencyMode: .secondaryAsLocal)
        try context.save()

        let csv = CardCSVHelper.generateCSV(from: [card])
        context.delete(card)
        try context.save()

        try CardCSVHelper.parseCSV(content: csv, into: context)
        let restored = try XCTUnwrap(try context.fetch(FetchDescriptor<CreditCard>()).first)
        XCTAssertEqual(restored.rewardType, .points)
        XCTAssertEqual(restored.pointProgram?.pointName, "RC", "有双币列的新版 CSV 也要能导回积分计划")
        XCTAssertEqual(try XCTUnwrap(restored.pointProgram?.pointValue), 1.25, accuracy: 0.000001)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Point>()).count, 1, "应复用已有的积分计划，不新建")
    }

    func testCardCSVWithoutPointColumnsMatchesExistingProgramByName() throws {
        let point = Point(bankName: "HSBC HK", pointName: "RC", pointValue: 1.25, valueCurrencyCode: .hk)
        context.insert(point)
        let card = makeCard(defaultRate: 1.0, rewardType: .points, pointProgram: point,
                            secondaryRegion: .cn, dualCurrencyMode: .secondaryAsLocal)
        try context.save()

        // 模拟上一版导出的格式：有双币列、没有积分价值 / 币种两列
        let lines = CardCSVHelper.generateCSV(from: [card]).components(separatedBy: "\n")
        let stripped = lines.map { line -> String in
            guard !line.isEmpty else { return line }
            var cols = line.components(separatedBy: ",")
            cols.removeLast(2)
            return cols.joined(separator: ",")
        }.joined(separator: "\n")
        context.delete(card)
        try context.save()

        try CardCSVHelper.parseCSV(content: stripped, into: context)
        let restored = try XCTUnwrap(try context.fetch(FetchDescriptor<CreditCard>()).first)
        XCTAssertEqual(restored.pointProgram?.pointName, "RC", "旧格式按名称 + 银行匹配已有计划")
    }

    // MARK: - 四、2 / 四、3 交易 CSV

    func testTransactionCSVRoundTripKeepsSourceDedupeIDAndCategory() throws {
        let card = makeCard(issueRegion: .us)
        let tx = Transaction(merchant: "Whole Foods", category: .grocery, location: .us, amount: 42,
                             date: day("2026-07-10"), card: card, billingAmount: 42, cashbackAmount: 0.42,
                             paymentMethod: .online, billingCurrencyCode: "USD", source: .plaid)
        tx.dedupeID = "plaid|2026-07-10|4200|tok"
        context.insert(tx)
        try context.save()

        let csv = [tx].generateCSV()
        XCTAssertTrue(csv.contains(",grocery,"), "类别用 rawValue 导出")
        context.delete(tx)
        try context.save()

        let restored = try CSVHelper.parseTransactionCSV(content: csv, context: context, allCards: [card])
        let row = try XCTUnwrap(restored.first)
        XCTAssertEqual(row.source, .plaid)
        XCTAssertEqual(row.dedupeID, "plaid|2026-07-10|4200|tok")
        XCTAssertEqual(row.category, .grocery)
        XCTAssertEqual(row.paymentMethod, .online)
    }

    func testTransactionCSVAcceptsLocalizedCategoryNames() throws {
        let lookup = CSVHelper.categoryLookup()
        XCTAssertEqual(lookup["dining"], .dining)
        XCTAssertEqual(lookup["餐饮美食"], .dining)
        XCTAssertEqual(lookup[Category.dining.displayName], .dining)
        // 英文显示名（跨语言导入）
        if let enPath = Bundle.main.path(forResource: "en", ofType: "lproj"), let en = Bundle(path: enPath) {
            let english = en.localizedString(forKey: "餐饮美食", value: nil, table: nil)
            XCTAssertEqual(lookup[english], .dining, "英文界面导出的类别名也要认")
        }

        let header = "交易时间,商户名称,消费类别,消费金额(原币),入账金额,返现金额,支付卡片,卡片尾号,消费地区,支付方式,积分数,入账币种\n"
        let csv = header
            + "2026-07-10,\"A\",餐饮美食,10.00,10.00,0.10,已删除卡片,无卡,香港,offline,0,HKD\n"
            + "2026-07-11,\"B\",Dining,10.00,10.00,0.10,已删除卡片,无卡,香港,offline,0,HKD\n"
            + "2026-07-12,\"C\",travel,10.00,10.00,0.10,已删除卡片,无卡,香港,offline,0,HKD\n"
        let rows = try CSVHelper.parseTransactionCSV(content: csv, context: context, allCards: [])
            .sorted { $0.date < $1.date }
        XCTAssertEqual(rows.map(\.category), [.dining, .dining, .travel])
        XCTAssertEqual(rows.first?.source, .manual, "旧版 CSV 没有来源列时默认手动")
    }
}
