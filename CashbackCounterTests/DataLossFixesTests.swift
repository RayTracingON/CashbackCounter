import XCTest
import SwiftData
@testable import CashbackCounter

private typealias Category = CashbackCounter.Category
private typealias Transaction = CashbackCounter.Transaction

/// 四处会丢用户数据的修复，各自守一条：
///
///   1. 数据库打不开时**只挪不删**，而且 SQLite 边车文件名要对（`-wal` 不是 `.wal`）
///   2. Plaid 退款作为负数交易入库，重复拉回**永远不删任何一笔**真实消费
///   3. 去重键写进 dedupeID，换时区后不再整窗重复插入
///   4. 远端模板 JSON 有一条解不开只丢那一条；卡片去重要求规则完全一致
@MainActor
final class DataLossFixesTests: XCTestCase {

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

    // MARK: - 1. 数据库兜底：只挪不删

    func testStoreFilesAreMovedAsideNotDeleted() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("default.store")
        let sidecars = ["default.store-shm", "default.store-wal"].map { dir.appendingPathComponent($0) }
        try Data([0x01]).write(to: store)
        for url in sidecars { try Data([0x02]).write(to: url) }

        // 边车文件名：完整文件名后接 -shm / -wal，不是换扩展名
        XCTAssertEqual(
            SharedModelContainer.storeFileURLs(for: store).map(\.lastPathComponent),
            ["default.store", "default.store-shm", "default.store-wal"])

        let backup = try XCTUnwrap(
            SharedModelContainer.moveStoreAside(storeURL: store, now: Date(timeIntervalSince1970: 0)))

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), "原位置应该空出来给新库")
        for url in sidecars {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) 也要一起搬走")
        }
        let moved = try FileManager.default.contentsOfDirectory(atPath: backup.path).sorted()
        XCTAssertEqual(moved, ["default.store", "default.store-shm", "default.store-wal"],
                       "三个文件都应原样搬进备份目录，一个都不能删")
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("default.store")), Data([0x01]))
        XCTAssertTrue(backup.path.contains("StoreBackups"))
    }

    func testMoveAsideWithNothingToMoveReturnsNil() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("default.store")
        XCTAssertNil(SharedModelContainer.moveStoreAside(storeURL: missing))
    }

    // MARK: - Plaid 夹具

    private func makeCard(endNum: String = "1234", defaultRate: Double = 0.02) -> CreditCard {
        let card = CreditCard(
            bankName: "Chase", type: "Freedom", endNum: endNum,
            colorHexes: ["000000"], defaultRate: defaultRate,
            specialRates: [:], issueRegion: .us)
        context.insert(card)
        return card
    }

    private func makeAccount(card: CreditCard, accountId: String = "acct-1") -> LinkedBankAccount {
        let account = LinkedBankAccount(
            itemId: "item-1", accountId: accountId,
            institutionName: "Chase", accountName: "Freedom", mask: card.endNum,
            card: card, syncEnabled: true)
        context.insert(account)
        return account
    }

    private func dto(_ date: String, _ amount: Double,
                     merchant: String = "Netflix",
                     accountId: String = "acct-1") -> PlaidTransactionDTO {
        PlaidTransactionDTO(
            accountId: accountId, accountName: "Freedom", accountMask: "1234",
            date: date, name: merchant, merchantName: merchant,
            amount: amount, currency: "USD", pending: false,
            category: "ENTERTAINMENT", categoryDetailed: "ENTERTAINMENT_TV_AND_MOVIES",
            paymentChannel: "online")
    }

    private func plaidRows() throws -> [Transaction] {
        try context.fetch(FetchDescriptor<Transaction>())
            .filter { $0.source == .plaid }
            .sorted { $0.date < $1.date }
    }

    @discardableResult
    private func run(_ dtos: [PlaidTransactionDTO],
                     accounts: [LinkedBankAccount]) async throws -> PlaidSyncService.SyncSummary {
        let summary = await PlaidSyncService.shared.process(dtos, accounts: accounts, pointValues: [:], context: context)
        try context.save()
        return summary
    }

    // MARK: - 2. 退款：负数入库，重复拉回不删任何消费

    /// 事故原型：Netflix 月费三笔，退了 6/1 那笔。旧逻辑第一次删 6/1（对），
    /// 之后每次同步退款再被拉回时又按"等额"删 5/1、4/1 —— 三笔真实消费全部消失。
    func testRefundIsStoredAsNegativeRowAndRepeatedSyncsNeverDeletePurchases() async throws {
        let card = makeCard()
        let account = makeAccount(card: card)
        try context.save()

        let batch = [
            dto("2026-04-01", 15.49), dto("2026-05-01", 15.49), dto("2026-06-01", 15.49),
            dto("2026-06-05", -15.49)
        ]
        let first = try await run(batch, accounts: [account])
        XCTAssertEqual(first.inserted, 3)
        XCTAssertEqual(first.refundsApplied, 1)

        var rows = try plaidRows()
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.filter { $0.billingAmount < 0 }.count, 1, "退款应是一笔负数交易")
        XCTAssertEqual(rows.reduce(0) { $0 + $1.billingAmount }, 15.49 * 2, accuracy: 0.001, "净支出 = 两笔月费")

        // 同一笔退款因为增量窗口重叠被连续拉回 3 次
        for _ in 0..<3 {
            let again = try await run([dto("2026-06-05", -15.49)], accounts: [account])
            XCTAssertEqual(again.refundsApplied, 0)
            XCTAssertEqual(again.inserted, 0)
            XCTAssertEqual(again.duplicatesSkipped, 1, "已入库的退款应被数量对齐跳过")
        }
        rows = try plaidRows()
        XCTAssertEqual(rows.count, 4, "重复拉回的退款不能删掉任何一笔真实消费")
        XCTAssertEqual(rows.filter { $0.billingAmount > 0 }.count, 3, "三笔月费一笔都不能少")
    }

    func testWholeBatchIsIdempotent() async throws {
        let card = makeCard()
        let account = makeAccount(card: card)
        try context.save()
        let batch = [dto("2026-06-01", 15.49), dto("2026-06-01", 15.49), dto("2026-06-05", -15.49)]

        let first = try await run(batch, accounts: [account])
        XCTAssertEqual(first.inserted, 2, "同日同额两杯咖啡是两笔真实交易")
        XCTAssertEqual(first.refundsApplied, 1)

        let second = try await run(batch, accounts: [account])
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.refundsApplied, 0)
        XCTAssertEqual(second.duplicatesSkipped, 3)
        XCTAssertEqual(try plaidRows().count, 3)
    }

    func testRefundMatchesPurchaseAlreadyInStore() async throws {
        let card = makeCard()
        let account = makeAccount(card: card)
        try context.save()

        try await run([dto("2026-06-01", 15.49)], accounts: [account])
        let summary = try await run([dto("2026-06-05", -15.49)], accounts: [account])
        XCTAssertEqual(summary.refundsApplied, 1, "原消费在库里（上一批同步的）也要能配上")
        XCTAssertEqual(try plaidRows().count, 2)
    }

    func testUnmatchedRefundIsIgnoredNotInserted() async throws {
        let card = makeCard()
        let account = makeAccount(card: card)
        try context.save()

        let summary = try await run([dto("2026-06-05", -15.49)], accounts: [account])
        XCTAssertEqual(summary.refundsUnmatched, 1)
        XCTAssertEqual(summary.refundsApplied, 0)
        XCTAssertEqual(try plaidRows().count, 0, "找不到原消费的退款不能凭空造一笔负数")
    }

    func testSameDayPurchaseAndRefundAreDifferentDedupeGroups() async throws {
        let card = makeCard()
        let account = makeAccount(card: card)
        try context.save()

        let summary = try await run([dto("2026-06-05", 15.49), dto("2026-06-05", -15.49)], accounts: [account])
        XCTAssertEqual(summary.inserted, 1)
        XCTAssertEqual(summary.refundsApplied, 1, "去重键带符号，退款不能被当成消费的重复")
    }

    func testRefundRowCarriesNegativeCashback() async throws {
        let card = makeCard(defaultRate: 0.02)
        let account = makeAccount(card: card)
        try context.save()

        try await run([dto("2026-06-01", 100), dto("2026-06-05", -100)], accounts: [account])
        let refund = try XCTUnwrap(try plaidRows().first { $0.billingAmount < 0 })
        XCTAssertEqual(refund.billingAmount, -100, accuracy: 0.001)
        XCTAssertEqual(refund.cashbackamount, -2, accuracy: 0.001, "退款的返现跟着回冲")
    }

    // MARK: - 3. 去重键时区无关

    func testDedupeKeyLivesInDedupeIDAndSurvivesTimezoneShift() async throws {
        let card = makeCard()
        let account = makeAccount(card: card)
        try context.save()

        try await run([dto("2026-07-10", 42.00)], accounts: [account])
        let row = try XCTUnwrap(try plaidRows().first)
        let parsed = try XCTUnwrap(PlaidSyncService.parsePlaidDedupeID(row.dedupeID))
        XCTAssertEqual(parsed.day, "2026-07-10")
        XCTAssertEqual(parsed.cents, 4200)

        // 模拟换时区：同一瞬间在新时区落到了前一天。把 Date 往前拨 20 小时。
        row.date = row.date.addingTimeInterval(-20 * 3600)
        try context.save()

        let again = try await run([dto("2026-07-10", 42.00)], accounts: [account])
        XCTAssertEqual(again.inserted, 0, "日期键来自 dedupeID，不该因为 Date 落到别的自然日而重复插入")
        XCTAssertEqual(try plaidRows().count, 1)
    }

    func testLegacyRowIsUpgradedToStructuredDedupeID() async throws {
        let card = makeCard()
        let account = makeAccount(card: card)

        // 旧版本同步进来的行：dedupeID 还是裸 UUID，Date 是本地午夜
        let midnight = try XCTUnwrap(PlaidSyncService.localDayFormatter.date(from: "2026-07-10"))
        let legacy = Transaction(
            merchant: "Netflix", category: .streaming, location: .us,
            amount: 42, date: midnight, card: card, billingAmount: 42, cashbackAmount: 0.84,
            paymentMethod: .online, billingCurrencyCode: "USD", source: .plaid)
        context.insert(legacy)
        card.transactions = [legacy]
        let oldID = legacy.dedupeID
        XCTAssertFalse(PlaidSyncService.isPlaidDedupeID(oldID))
        try context.save()

        let summary = try await run([dto("2026-07-10", 42.00)], accounts: [account])
        XCTAssertEqual(summary.inserted, 0, "旧行按 Date 推出的自然日仍能对上")
        XCTAssertEqual(summary.duplicatesSkipped, 1)
        XCTAssertEqual(legacy.dedupeID, "plaid|2026-07-10|4200|\(oldID)",
                       "升级后保留旧 UUID 当 token，CloudKit 副本仍共用同一个 dedupeID")
    }

    func testPlaidDedupeIDRoundTrip() {
        let id = PlaidSyncService.plaidDedupeID(dayKey: "2026-01-31", cents: -1549, token: "tok")
        XCTAssertEqual(id, "plaid|2026-01-31|-1549|tok")
        let parsed = PlaidSyncService.parsePlaidDedupeID(id)
        XCTAssertEqual(parsed?.day, "2026-01-31")
        XCTAssertEqual(parsed?.cents, -1549)
        XCTAssertNil(PlaidSyncService.parsePlaidDedupeID(UUID().uuidString))
        XCTAssertNil(PlaidSyncService.parsePlaidDedupeID(""))
        XCTAssertFalse(PlaidSyncService.plaidDedupeID(dayKey: "2026-01-31", cents: 1, token: "").hasSuffix("|"),
                       "空 token 要补一个 UUID")
    }

    // MARK: - 4. 模板解码容错 + 卡片去重只合并规则一致的

    /// 和打包的 CardTemplates.json 同一种形态（字典编码成交替数组、capPeriod 是 {"yearly":{}}）
    private func templateJSON(type: String, region: String = "香港",
                              paymentMethod: String? = nil) -> String {
        let pm = paymentMethod.map { "[\"\($0)\", 5]" } ?? "[]"
        return """
        {
          "capPeriod" : { "yearly" : { } },
          "specialRate" : [ "dining", 3 ],
          "pictureURL" : "",
          "type" : "\(type)",
          "foreignBaseCap" : 0,
          "localBaseCap" : 0,
          "categoryCaps" : [ ],
          "rewardType" : "cashback",
          "region" : "\(region)",
          "paymentCaps" : [ ],
          "colors" : [ "000000", "FFFFFF" ],
          "foreignCurrencyRate" : 2,
          "paymentMethodRates" : \(pm),
          "memo" : "",
          "bankName" : "测试银行",
          "defaultRate" : 1
        }
        """
    }

    func testTemplateDecodingSkipsOnlyTheUndecodableEntries() throws {
        let json = "[\(templateJSON(type: "好卡")),\(templateJSON(type: "火星卡", region: "火星")),\(templateJSON(type: "新支付卡", paymentMethod: "wechat"))]"
        let result = try CardTemplateManager.decodeTemplates(from: Data(json.utf8))
        XCTAssertEqual(result.templates.map(\.type), ["好卡"], "本版本不认识的地区 / 支付方式只丢那一条")
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(result.templates.first?.specialRate[.dining], 3)
        XCTAssertEqual(result.templates.first?.capPeriod, .yearly)
    }

    func testTemplateDecodingThrowsWhenNothingDecodes() {
        XCTAssertThrowsError(try CardTemplateManager.decodeTemplates(from: Data("[{\"bankName\":\"x\"}]".utf8)))
        XCTAssertThrowsError(try CardTemplateManager.decodeTemplates(from: Data("not json".utf8)))
    }

    func testEmptyTemplateArrayIsNotAnError() throws {
        let result = try CardTemplateManager.decodeTemplates(from: Data("[]".utf8))
        XCTAssertTrue(result.templates.isEmpty)
        XCTAssertEqual(result.skipped, 0)
    }

    func testBundledTemplatesDecodeWithoutSkips() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "CardTemplates", withExtension: "json"))
        let result = try CardTemplateManager.decodeTemplates(from: Data(contentsOf: url))
        XCTAssertEqual(result.skipped, 0, "打包的模板必须每一条都能解")
        XCTAssertFalse(result.templates.isEmpty)
    }

    func testCardsWithSameIdentityButDifferentRulesAreNotMerged() throws {
        _ = makeCard(endNum: "1234", defaultRate: 0.01)
        _ = makeCard(endNum: "1234", defaultRate: 0.02)
        try context.save()

        CardTemplateManager.shared.deduplicateCards(in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CreditCard>()).count, 2,
                       "费率不同就不是同一张卡的副本，不能合并")
    }

    func testIdenticalCardsAreStillMerged() throws {
        _ = makeCard(endNum: "1234", defaultRate: 0.02)
        _ = makeCard(endNum: "1234", defaultRate: 0.02)
        try context.save()

        CardTemplateManager.shared.deduplicateCards(in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CreditCard>()).count, 1,
                       "逐字段相同的 CloudKit 副本仍要合并")
    }

    func testTemplatePrefillLeavesEndNumberEmpty() throws {
        let template = try XCTUnwrap(
            CardTemplateManager.decodeTemplates(from: Data("[\(templateJSON(type: "好卡"))]".utf8)).templates.first)
        let viewModel = AddCardViewModel(template: template)
        XCTAssertEqual(viewModel.endNum, "", "不再预填 8888：两张没改尾号的模板卡会被当成同一张合并")
        XCTAssertEqual(viewModel.bankName, "测试银行")
    }
}
