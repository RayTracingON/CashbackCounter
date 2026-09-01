import XCTest
import SwiftData
@testable import CashbackCounter

private typealias Category = CashbackCounter.Category

/// 去重与币种归属的回归测试。
///
/// 这三组用例守的都是**静默数据丢失**：删错一笔账、切断一条银行绑定、
/// 把外币返现当成本币统计 —— 共同点是用户在界面上完全看不出来。
/// 参考 SchemaCloudKitTests 的理由：这类问题必须在测试里挡住。
@MainActor
final class DeduplicationTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema([
            Transaction.self, CreditCard.self, Income.self,
            Point.self, PointAdjustment.self, LinkedBankAccount.self
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

    // MARK: - Helpers

    private func makeCard(bank: String = "TestBank",
                          type: String = "TestCard",
                          endNum: String = "1234",
                          issueRegion: Region = .hk) -> CreditCard {
        let card = CreditCard(
            bankName: bank, type: type, endNum: endNum,
            colorHexes: ["FF0000"], defaultRate: 0.01,
            specialRates: [:], issueRegion: issueRegion)
        context.insert(card)
        return card
    }

    @discardableResult
    private func makeTransaction(card: CreditCard?,
                                 merchant: String = "Starbucks",
                                 amount: Double = 38,
                                 date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Transaction {
        let tx = Transaction(
            merchant: merchant, category: .dining, location: .hk,
            amount: amount, date: date, card: card)
        context.insert(tx)
        card?.transactions = (card?.transactions ?? []) + [tx]
        return tx
    }

    // MARK: - 交易去重

    /// 同一天在同一家店买两杯一样的咖啡 —— 两笔内容完全相同的**真实**交易。
    /// 旧实现按内容指纹去重，会把第二杯永久删掉，而且每次 App 更新都删一次。
    func testIdenticalTransactionsAreNeverMerged() throws {
        let card = makeCard()
        makeTransaction(card: card)
        makeTransaction(card: card)
        try context.save()

        CardTemplateManager.shared.deduplicateTransactions(in: context)

        let remaining = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(remaining.count, 2,
                       "两笔内容相同但独立建档的交易被合并了 —— 用户的账每次升级都会少一笔")
        XCTAssertNotEqual(remaining[0].dedupeID, remaining[1].dedupeID,
                          "独立建档的交易必须拿到不同的 dedupeID")
    }

    /// CloudKit 重新导入产生的副本会连 dedupeID 一起复制，这种才该合并。
    func testCloudKitDuplicateSharingDedupeIDIsMerged() throws {
        let card = makeCard()
        let original = makeTransaction(card: card)
        let cloudCopy = makeTransaction(card: card)
        // 模拟 CloudKit 复制：副本带着和原件一样的 dedupeID
        cloudCopy.dedupeID = original.dedupeID
        try context.save()

        CardTemplateManager.shared.deduplicateTransactions(in: context)

        let remaining = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(remaining.count, 1, "共享 dedupeID 的 CloudKit 副本应该被合并")
    }

    /// 合并时收据和关联收入要转移到保留的那一笔上，不能跟着副本一起删掉。
    func testMergeTransfersReceiptAndIncome() throws {
        let card = makeCard()
        let bare = makeTransaction(card: card)
        let rich = makeTransaction(card: card)
        rich.dedupeID = bare.dedupeID
        rich.receiptData = Data([0x01, 0x02])
        let income = Income(amount: 10, date: Date(), location: .hk, transaction: rich)
        context.insert(income)
        rich.incomes = [income]
        try context.save()

        CardTemplateManager.shared.deduplicateTransactions(in: context)

        let remaining = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.receiptData, Data([0x01, 0x02]), "收据不该跟着副本被删掉")
        XCTAssertEqual(remaining.first?.incomes?.count, 1, "关联收入应转移到保留的那一笔")
    }

    /// 旧数据 dedupeID 为空：就地补 UUID，且**一笔都不能删**。
    func testLegacyTransactionsAreBackfilledNotDeleted() throws {
        let card = makeCard()
        let a = makeTransaction(card: card)
        let b = makeTransaction(card: card)
        a.dedupeID = ""
        b.dedupeID = ""
        try context.save()

        CardTemplateManager.shared.deduplicateTransactions(in: context)

        let remaining = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(remaining.count, 2, "旧数据没有标识，无法判定是否重复，绝不能删")
        XCTAssertTrue(remaining.allSatisfy { !$0.dedupeID.isEmpty }, "旧数据应被补上 dedupeID")
        XCTAssertNotEqual(remaining[0].dedupeID, remaining[1].dedupeID)
    }

    // MARK: - 卡片去重

    /// 合并重复卡片时必须把银行绑定转移到 master。
    /// 漏了会让 LinkedBankAccount.card 被 nullify —— isSyncable 变 false，
    /// 那张卡从此静默停止同步，界面上只显示成"未关联"。
    func testCardDeduplicationTransfersLinkedBankAccounts() throws {
        let master = makeCard()
        makeTransaction(card: master)   // master 交易更多，会被选作保留方
        let duplicate = makeCard()

        let account = LinkedBankAccount(
            itemId: "item-1", accountId: "acct-1",
            institutionName: "Chase", accountName: "Sapphire", mask: "1234",
            card: duplicate, syncEnabled: true)
        context.insert(account)
        try context.save()

        CardTemplateManager.shared.deduplicateCards(in: context)

        let cards = try context.fetch(FetchDescriptor<CreditCard>())
        XCTAssertEqual(cards.count, 1, "重复卡片应被合并")

        let accounts = try context.fetch(FetchDescriptor<LinkedBankAccount>())
        XCTAssertEqual(accounts.count, 1)
        XCTAssertNotNil(accounts.first?.card, "银行绑定不该在合并卡片时被切断")
        XCTAssertTrue(accounts.first?.isSyncable ?? false, "合并后这张卡必须仍然可同步")
    }

    /// master 已经绑着同一个 Plaid 账户时，副本那条是纯冗余指针，留着会变成僵尸记录。
    func testCardDeduplicationDropsRedundantLinkedAccount() throws {
        let master = makeCard()
        makeTransaction(card: master)
        let duplicate = makeCard()

        for card in [master, duplicate] {
            let account = LinkedBankAccount(
                itemId: "item-1", accountId: "acct-1",
                institutionName: "Chase", accountName: "Sapphire", mask: "1234",
                card: card, syncEnabled: true)
            context.insert(account)
        }
        try context.save()

        CardTemplateManager.shared.deduplicateCards(in: context)

        let accounts = try context.fetch(FetchDescriptor<LinkedBankAccount>())
        XCTAssertEqual(accounts.count, 1, "同一个 accountId 只该留一条绑定")
        XCTAssertTrue(accounts.first?.isSyncable ?? false)
    }

    /// 卡面图不该跟着副本一起被删掉。
    func testCardDeduplicationKeepsCardImage() throws {
        let master = makeCard()
        makeTransaction(card: master)
        let duplicate = makeCard()
        duplicate.cardImageData = Data([0xAA])
        try context.save()

        CardTemplateManager.shared.deduplicateCards(in: context)

        let cards = try context.fetch(FetchDescriptor<CreditCard>())
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.cardImageData, Data([0xAA]), "master 没有卡面图时应从副本接过来")
    }

    // MARK: - 删卡后的币种归属

    /// 卡被删掉后交易变成"无卡"，但 billingCurrencyCode 还在。
    /// 旧代码在 card == nil 时直接改用主币种，等于把存好的正确币种丢掉。
    func testOrphanedTransactionKeepsItsBillingCurrency() throws {
        let card = makeCard(issueRegion: .hk)
        let tx = makeTransaction(card: card)
        XCTAssertEqual(tx.resolvedBillingCurrencyCode, "HKD")

        context.delete(card)
        try context.save()

        XCTAssertNil(tx.card, "删卡后交易应变成无卡")
        XCTAssertEqual(tx.resolvedBillingCurrencyCode, "HKD",
                       "入账币种是存下来的事实，不该因为卡片被删就变成主币种")
    }

    /// 同一笔无卡交易，支出和返现必须用同一个币种口径换算。
    /// 修复前：支出走 resolvedBillingCurrencyCode（按 HKD 换算），
    /// 返现走主币种（汇率 1.0 不换算），同一笔交易两个口径。
    func testExpenseAndCashbackUseTheSameCurrencyForOrphanedTransaction() throws {
        let card = makeCard(issueRegion: .hk)
        let tx = makeTransaction(card: card, amount: 100)
        tx.billingAmount = 100
        tx.cashbackamount = 10
        context.delete(card)
        try context.save()

        let vm = BillHomeViewModel()
        vm.exchangeRates = ["HKD": 1.1, "hkd": 1.1]   // base = CNY

        let expense = vm.expenseInMainCurrency(for: tx, mainCurrencyCode: "CNY")
        let cashback = vm.totalCashback(from: [tx], mainCurrencyCode: "CNY")

        XCTAssertEqual(expense.currencyCode, "HKD")
        XCTAssertEqual(expense.amount, 100 / 1.1, accuracy: 0.0001)
        XCTAssertEqual(cashback, 10 / 1.1, accuracy: 0.0001,
                       "返现必须和支出用同一个汇率换算，否则同一笔交易两个口径")
    }
}
