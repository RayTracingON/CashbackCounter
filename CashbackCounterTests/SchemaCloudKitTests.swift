import XCTest
import SwiftData
@testable import CashbackCounter

/// 校验 schema 满足 CloudKit 的约束。
///
/// 存在的理由是一次真实的数据丢失：SharedModelContainer 在 ModelContainer
/// 初始化失败时会**删除本地数据库重建**。所以任何让 schema 变得不合法的改动，
/// 后果不是"启动报错"，而是"用户的卡包和账单全没了"。
/// 这类问题必须在测试里挡住，不能等真机上发现。
final class SchemaCloudKitTests: XCTestCase {

    /// 完整 schema 在启用 CloudKit 的配置下必须能初始化。
    ///
    /// CloudKit 的硬性要求：属性有默认值、关系可空、无 unique 约束、
    /// **且每个关系都要有 inverse**。少一条这里就抛。
    func testSchemaIsCloudKitCompatible() throws {
        let schema = Schema([
            Transaction.self, CreditCard.self, Income.self, Point.self, PointAdjustment.self,
            LinkedBankAccount.self
        ])

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        let config = ModelConfiguration(
            schema: schema,
            url: url,
            cloudKitDatabase: .private("iCloud.CashbackCounter"))

        XCTAssertNoThrow(
            try ModelContainer(for: schema, configurations: [config]),
            "schema 不满足 CloudKit 约束 —— 真机上会导致 SharedModelContainer 删库重建")
    }

    /// LinkedBankAccount ↔ CreditCard 的关系两边都要能走通
    func testLinkedBankAccountRelationshipRoundTrip() throws {
        let schema = Schema([
            Transaction.self, CreditCard.self, Income.self, Point.self, PointAdjustment.self,
            LinkedBankAccount.self
        ])
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)

        let card = CreditCard(
            bankName: "Chase", type: "Sapphire", endNum: "1234",
            colorHexes: ["FF0000"], defaultRate: 0.01,
            specialRates: [:], issueRegion: .us)
        context.insert(card)

        let account = LinkedBankAccount(
            itemId: "item-1", accountId: "acct-1",
            institutionName: "Chase", accountName: "Sapphire", mask: "1234",
            card: card, syncEnabled: true)
        context.insert(account)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<LinkedBankAccount>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.card?.endNum, "1234")
        XCTAssertTrue(fetched.first?.isSyncable ?? false)

        // 删卡不该删掉绑定记录，只把 card 置空
        context.delete(card)
        try context.save()

        let afterDelete = try context.fetch(FetchDescriptor<LinkedBankAccount>())
        XCTAssertEqual(afterDelete.count, 1, "删卡不应连带删除绑定记录")
        XCTAssertNil(afterDelete.first?.card)
        XCTAssertFalse(afterDelete.first?.isSyncable ?? true, "没有卡片就不该被认为可同步")
    }
}
