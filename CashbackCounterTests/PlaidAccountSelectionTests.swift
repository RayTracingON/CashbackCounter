//
//  PlaidAccountSelectionTests.swift
//  CashbackCounterTests
//
//  「单账户解绑」（Plaid Link update mode + Account Select）的回归测试。
//
//  和 DeduplicationTests 守的是同一类问题：**静默的数据丢失**。
//  这里具体是三件事 ——
//    · 解绑按钮指错 item（同一家银行绑两次时）
//    · reconcile 把还在用的账户连同它的同步状态一起删掉
//    · 远端返回空列表时被当成「用户取消了全部账户」而清空本地
//  三件的共同点都是用户在界面上完全看不出来。
//

import XCTest
import SwiftData
@testable import CashbackCounter

@MainActor
final class PlaidAccountSelectionTests: XCTestCase {

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

    @discardableResult
    private func makeAccount(itemId: String,
                             accountId: String,
                             institution: String = "Chase",
                             name: String = "Sapphire",
                             mask: String = "1234",
                             card: CreditCard? = nil,
                             syncEnabled: Bool = false) -> LinkedBankAccount {
        let account = LinkedBankAccount(
            itemId: itemId,
            accountId: accountId,
            institutionName: institution,
            accountName: name,
            mask: mask,
            card: card,
            syncEnabled: syncEnabled)
        context.insert(account)
        return account
    }

    @discardableResult
    private func makeCard(endNum: String) -> CreditCard {
        let card = CreditCard(
            bankName: "Chase", type: "Sapphire", endNum: endNum,
            colorHexes: ["0000FF"], defaultRate: 0.01,
            specialRates: [:], issueRegion: .hk)
        context.insert(card)
        return card
    }

    /// 后端 `/api/plaid/accounts` 的一行
    private func remoteAccount(_ accountId: String,
                               name: String = "Sapphire",
                               mask: String = "1234") -> PlaidAccountDTO {
        PlaidAccountDTO(
            accountId: accountId,
            name: name,
            officialName: nil,
            mask: mask,
            type: "credit",
            subtype: "credit card",
            currentBalance: nil,
            availableBalance: nil,
            creditLimit: nil,
            currency: "USD")
    }

    // MARK: - 分组：解绑按钮必须指得准

    /// 同一家银行绑两次（个人号 + 商务号，或断连后重绑）会产生**两个 itemId**。
    /// 按 institutionName 分组会把它们塞进同一个 section，
    /// 那时「解绑 XX 银行」只会删掉 `.first` 那个 item —— 而 `.first` 落在哪个
    /// item 上取决于排序，确认弹窗上那句「将撤销这家银行的授权」是假的。
    func testSameInstitutionWithTwoItemsProducesTwoGroups() throws {
        makeAccount(itemId: "item-A", accountId: "acc-1", mask: "1111")
        makeAccount(itemId: "item-B", accountId: "acc-2", mask: "2222")
        try context.save()

        let groups = groupAccountsByItem(try context.fetch(FetchDescriptor<LinkedBankAccount>()))

        XCTAssertEqual(groups.count, 2,
                       "同名银行的两个 item 被合并成一个 section —— 解绑按钮会指错 item")
        XCTAssertEqual(Set(groups.map(\.itemId)), ["item-A", "item-B"])
    }

    /// header 必须能把两个同名 item 区分开，否则用户面对两个一模一样的
    /// 「Chase」section，根本不知道该点哪个。
    func testDuplicateInstitutionHeadersCarryMasks() throws {
        makeAccount(itemId: "item-A", accountId: "acc-1", mask: "1111")
        makeAccount(itemId: "item-B", accountId: "acc-2", mask: "2222")
        try context.save()

        let titles = groupAccountsByItem(try context.fetch(FetchDescriptor<LinkedBankAccount>()))
            .map(\.title)

        XCTAssertEqual(titles, ["Chase ···1111", "Chase ···2222"])
    }

    /// 只有一个 item 时不该加尾号 —— 每个 section 都挂一串尾号只是噪音。
    func testSingleItemHeaderIsPlainInstitutionName() throws {
        makeAccount(itemId: "item-A", accountId: "acc-1", mask: "1111")
        makeAccount(itemId: "item-A", accountId: "acc-2", mask: "2222")
        try context.save()

        let groups = groupAccountsByItem(try context.fetch(FetchDescriptor<LinkedBankAccount>()))

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].title, "Chase")
        XCTAssertEqual(groups[0].accounts.count, 2)
    }

    // MARK: - reconcile：对齐 Plaid 的最新状态

    /// update mode 的核心用例：一个 item 下两张卡，用户只取消勾选了其中一张。
    func testReconcileRemovesOnlyTheDeselectedAccount() throws {
        makeAccount(itemId: "item-A", accountId: "acc-keep", mask: "1111")
        makeAccount(itemId: "item-A", accountId: "acc-drop", mask: "2222")
        try context.save()

        let result = try PlaidLinkService.shared.reconcile(
            itemId: "item-A",
            remote: [remoteAccount("acc-keep", mask: "1111")],
            context: context)

        XCTAssertEqual(result, .aligned(removed: 1, added: 0))

        let remaining = try context.fetch(FetchDescriptor<LinkedBankAccount>())
        XCTAssertEqual(remaining.map(\.accountId), ["acc-keep"])
    }

    /// 保留下来的账户**一个字段都不能被重置**。
    /// 丢掉 didInitialSync 的后果是下次同步重跑 730 天全量；
    /// 丢掉 card 关联的后果是这张卡静默停止同步（isSyncable 变 false）。
    func testReconcilePreservesStateOfKeptAccounts() throws {
        let card = makeCard(endNum: "1111")
        let kept = makeAccount(itemId: "item-A", accountId: "acc-keep",
                               mask: "1111", card: card, syncEnabled: true)
        kept.didInitialSync = true
        let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)
        kept.lastSyncedAt = syncedAt
        makeAccount(itemId: "item-A", accountId: "acc-drop", mask: "2222")
        try context.save()

        _ = try PlaidLinkService.shared.reconcile(
            itemId: "item-A",
            remote: [remoteAccount("acc-keep", mask: "1111")],
            context: context)

        let remaining = try XCTUnwrap(
            try context.fetch(FetchDescriptor<LinkedBankAccount>()).first)
        XCTAssertTrue(remaining.syncEnabled)
        XCTAssertTrue(remaining.didInitialSync, "didInitialSync 被重置 —— 下次同步会重跑 730 天全量")
        XCTAssertEqual(remaining.lastSyncedAt, syncedAt)
        XCTAssertIdentical(remaining.card, card)
    }

    /// 用户在 update mode 里**新勾选**了一个账户。
    /// 不建本地记录的话，它在 App 里完全不可见 —— 用户以为勾上了，实际什么都不同步。
    func testReconcileAddsNewlySelectedAccountAndMatchesMask() throws {
        let card = makeCard(endNum: "2222")
        makeAccount(itemId: "item-A", accountId: "acc-keep", mask: "1111")
        try context.save()

        let result = try PlaidLinkService.shared.reconcile(
            itemId: "item-A",
            remote: [remoteAccount("acc-keep", mask: "1111"),
                     remoteAccount("acc-new", name: "Freedom", mask: "2222")],
            context: context)

        XCTAssertEqual(result, .aligned(removed: 0, added: 1))

        let added = try XCTUnwrap(
            try context.fetch(FetchDescriptor<LinkedBankAccount>())
                .first { $0.accountId == "acc-new" })
        XCTAssertEqual(added.institutionName, "Chase", "银行名没有从同 item 的现有记录上继承")
        XCTAssertIdentical(added.card, card, "尾号唯一命中却没有自动关联卡片")
        XCTAssertTrue(added.syncEnabled)
    }

    /// 远端返回空数组是**可疑**状态，不是「用户取消了全部账户」。
    /// 照着删就是把一整家银行的本地状态一次抹掉，而且不可逆。
    func testEmptyRemoteLeavesLocalRecordsUntouched() throws {
        makeAccount(itemId: "item-A", accountId: "acc-1", mask: "1111", syncEnabled: true)
        makeAccount(itemId: "item-A", accountId: "acc-2", mask: "2222")
        try context.save()

        let result = try PlaidLinkService.shared.reconcile(
            itemId: "item-A", remote: [], context: context)

        XCTAssertEqual(result, .noRemoteAccounts)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LinkedBankAccount>()).count, 2,
                       "远端一个账户都没返回时删了本地记录 —— 这是不可逆的数据丢失")
    }

    /// 别的 item 不能被殃及：reconcile 是**按 item** 对齐的。
    func testReconcileDoesNotTouchOtherItems() throws {
        makeAccount(itemId: "item-A", accountId: "acc-1", mask: "1111")
        makeAccount(itemId: "item-B", accountId: "acc-2", institution: "Amex", mask: "2222")
        try context.save()

        _ = try PlaidLinkService.shared.reconcile(
            itemId: "item-A",
            remote: [remoteAccount("acc-1", mask: "1111")],
            context: context)

        let others = try context.fetch(FetchDescriptor<LinkedBankAccount>())
            .filter { $0.itemId == "item-B" }
        XCTAssertEqual(others.count, 1, "reconcile 动到了另一个 item 的记录")
    }

    /// 摘掉一个账户**不得**连带删除交易。
    /// 那些消费真实发生过，用户的返现统计建立在它们之上。
    func testReconcileNeverDeletesTransactions() throws {
        let card = makeCard(endNum: "2222")
        let tx = Transaction(merchant: "Starbucks", category: .dining, location: .hk,
                             amount: 38, date: Date(timeIntervalSince1970: 1_700_000_000),
                             card: card)
        context.insert(tx)
        makeAccount(itemId: "item-A", accountId: "acc-drop", mask: "2222", card: card, syncEnabled: true)
        makeAccount(itemId: "item-A", accountId: "acc-keep", mask: "1111")
        try context.save()

        _ = try PlaidLinkService.shared.reconcile(
            itemId: "item-A",
            remote: [remoteAccount("acc-keep", mask: "1111")],
            context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).count, 1,
                       "解绑单个账户时交易记录被连带删掉了")
    }
}
