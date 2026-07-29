import XCTest
import SwiftData
@testable import CashbackCounter

private typealias Category = CashbackCounter.Category
private typealias Transaction = CashbackCounter.Transaction

/// 同步进来的交易必须和手动记账用**同一套**奖励计算。
///
/// 存在的理由是一次真实事故：同步代码只把 card 传给 `Transaction.init`，
/// 没有预先算好 cashback / points，于是落进了构造器里那条朴素兜底路径
/// `cashbackamount = billingAmount * nominalRate`。
///
/// 对一张 Amex 这样的**积分卡**，那个 nominalRate 是"每元多少积分"（可能是 300），
/// 于是一笔 100 美元的消费被记成了 30000 的"返现" —— 数字荒谬，但没有任何报错，
/// 而且积分是 0。
@MainActor
final class PlaidRewardCalculationTests: XCTestCase {

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

    private func makeDTO(amount: Double, date: String = "2026-07-15") -> PlaidTransactionDTO {
        PlaidTransactionDTO(
            accountId: "acct-1",
            accountName: "Amex",
            accountMask: "1234",
            date: date,
            name: "Test Merchant",
            merchantName: "Test Merchant",
            amount: amount,
            currency: "USD",
            pending: false,
            category: "GENERAL_MERCHANDISE",
            categoryDetailed: "GENERAL_MERCHANDISE_OTHER",
            paymentChannel: "in store")
    }

    /// 积分卡：必须产出**积分**，而不是把积分倍率当返现乘进去
    func testPointsCardEarnsPointsNotInflatedCashback() throws {
        let program = Point(
            bankName: "Amex", pointName: "MR",
            pointValue: 0.05, valueCurrencyCode: .us)
        context.insert(program)

        // 每消费 1 美元得 3 点（这就是"费率"字段对积分卡的含义）
        let card = CreditCard(
            bankName: "Amex", type: "Gold", endNum: "1234",
            colorHexes: ["000000"], defaultRate: 3,
            specialRates: [:], issueRegion: .us,
            rewardType: .points, pointProgram: program)
        context.insert(card)
        try context.save()

        let dto = makeDTO(amount: 100)
        let transaction = PlaidSyncService.shared.makeTransaction(
            from: dto, card: card,
            pointValues: [card.persistentModelID: 0.05])

        // 100 美元 × 3 点 = 300 点
        XCTAssertEqual(transaction.pointsEarned, 300, "积分卡应该产出积分")

        // ⚠️ 核心断言：返现绝不能是 100 × 3 = 300。
        // 它应该是积分折算出的价值：300 点 × 0.05 = 15
        XCTAssertNotEqual(transaction.cashbackamount, 300,
                          "把积分倍率当返现乘进去了 —— 正是这次事故的症状")
        XCTAssertEqual(transaction.cashbackamount, 15, accuracy: 0.01,
                       "积分卡的 cashbackamount 应该是积分折算出的价值")
    }

    /// 返现卡：走 calculateCappedCashback，不产生积分
    func testCashbackCardEarnsCashbackNotPoints() throws {
        let card = CreditCard(
            bankName: "Chase", type: "Freedom", endNum: "5678",
            colorHexes: ["000000"], defaultRate: 0.02,
            specialRates: [:], issueRegion: .us,
            rewardType: .cashback)
        context.insert(card)
        try context.save()

        let transaction = PlaidSyncService.shared.makeTransaction(
            from: makeDTO(amount: 100), card: card, pointValues: [:])

        XCTAssertEqual(transaction.pointsEarned, 0, "返现卡不该产生积分")
        XCTAssertEqual(transaction.cashbackamount, 2.0, accuracy: 0.01, "100 × 2% = 2")
    }

    /// 上限必须生效。
    ///
    /// 构造器里那条兜底路径完全不看上限，所以这条测试同时守住了
    /// "同步没有绕过上限引擎"这件事。
    func testCapIsEnforcedForSyncedTransactions() throws {
        // 年度上限 5 元，2% 返现 → 250 元消费就到顶
        let card = CreditCard(
            bankName: "Test", type: "Capped", endNum: "9999",
            colorHexes: ["000000"], defaultRate: 0.02,
            specialRates: [:], issueRegion: .us,
            localBaseCap: 5, capPeriod: .yearly,
            rewardType: .cashback)
        context.insert(card)
        try context.save()

        // 第一笔 200 元 → 4 元返现，未到顶
        let first = PlaidSyncService.shared.makeTransaction(
            from: makeDTO(amount: 200), card: card, pointValues: [:])
        context.insert(first)
        card.transactions = [first]
        XCTAssertEqual(first.cashbackamount, 4.0, accuracy: 0.01)

        // 第二笔 200 元 → 理论 4 元，但只剩 1 元额度
        let second = PlaidSyncService.shared.makeTransaction(
            from: makeDTO(amount: 200), card: card, pointValues: [:])
        XCTAssertEqual(second.cashbackamount, 1.0, accuracy: 0.01,
                       "上限没生效 —— 说明同步绕过了上限引擎，或者第一笔没挂到 card.transactions 上")
    }
}
