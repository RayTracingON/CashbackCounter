import XCTest
import SwiftData
@testable import CashbackCounter

private typealias Category = CashbackCounter.Category

final class PointOperationTests: XCTestCase {

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

    private func makePoint(
        bankName: String = "TestBank",
        pointName: String = "TP",
        pointValue: Double = 0.01,
        valueCurrencyCode: Region = .hk
    ) -> Point {
        let point = Point(bankName: bankName, pointName: pointName, pointValue: pointValue, valueCurrencyCode: valueCurrencyCode)
        context.insert(point)
        return point
    }

    private func makeCard(
        defaultRate: Double = 1.0,
        specialRates: [Category: Double] = [:],
        paymentMethodRates: [PaymentMethod: Double] = [:],
        issueRegion: Region = .hk,
        foreignCurrencyRate: Double? = nil,
        localBaseCap: Double = 0,
        foreignBaseCap: Double = 0,
        categoryCaps: [Category: Double] = [:],
        paymentCaps: [PaymentMethod: Double] = [:],
        capPeriod: CapPeriod = .yearly,
        rewardType: RewardType = .points,
        pointProgram: Point? = nil
    ) -> CreditCard {
        let card = CreditCard(
            bankName: "TestBank",
            type: "TestCard",
            endNum: "1234",
            colorHexes: ["FF0000"],
            defaultRate: defaultRate,
            specialRates: specialRates,
            issueRegion: issueRegion,
            foreignCurrencyRate: foreignCurrencyRate,
            localBaseCap: localBaseCap,
            foreignBaseCap: foreignBaseCap,
            categoryCaps: categoryCaps,
            capPeriod: capPeriod,
            paymentMethodRates: paymentMethodRates,
            paymentCaps: paymentCaps,
            rewardType: rewardType,
            pointProgram: pointProgram
        )
        context.insert(card)
        return card
    }

    private func makeTransaction(card: CreditCard, amount: Double, category: Category, paymentMethod: PaymentMethod = .offline, location: Region = .hk, date: Date = Date()) -> Transaction {
        let tx = Transaction(
            merchant: "Test Merchant",
            category: category,
            location: location,
            amount: amount,
            date: date,
            card: card,
            paymentMethod: paymentMethod
        )
        context.insert(tx)
        return tx
    }

    // MARK: - 1. PointAdjustment 基础测试

    func testPointAdjustment_Earn() {
        let point = makePoint()
        let adj = PointAdjustment(pointProgram: point, points: 500, type: .earn, note: "消费获得")
        context.insert(adj)

        XCTAssertEqual(adj.points, 500)
        XCTAssertEqual(adj.type, .earn)
        XCTAssertEqual(adj.note, "消费获得")
        XCTAssertNotNil(adj.pointProgram)
    }

    func testPointAdjustment_Redeem() {
        let point = makePoint()
        let adj = PointAdjustment(pointProgram: point, points: -200, type: .redeem, note: "兑换礼品")
        context.insert(adj)

        XCTAssertEqual(adj.points, -200)
        XCTAssertEqual(adj.type, .redeem)
    }

    func testPointAdjustment_AllTypes() {
        let allTypes: [AdjustmentType] = [.earn, .redeem, .expire, .transfer, .bonus, .manual]

        for type in allTypes {
            XCTAssertFalse(type.displayName.isEmpty, "\(type) displayName should not be empty")
            XCTAssertFalse(type.iconName.isEmpty, "\(type) iconName should not be empty")
        }

        XCTAssertEqual(AdjustmentType.allCases.count, 6)
    }

    // MARK: - 2. Point 模型测试

    func testPointProgram_DisplayName() {
        let point = makePoint(bankName: "HSBC HK", pointName: "RC")
        XCTAssertEqual(point.displayName, "HSBC HK RC")
    }

    func testPointSeed_MakeModel() {
        let seed = PointSeed(bankName: "Chase", pointName: "UR", pointValue: 0.015, valueCurrencyCode: .us)
        let model = seed.makeModel()

        XCTAssertEqual(model.bankName, "Chase")
        XCTAssertEqual(model.pointName, "UR")
        XCTAssertEqual(model.pointValue, 0.015)
        XCTAssertEqual(model.valueCurrencyCode, .us)
        XCTAssertTrue(model.isActive)
    }

    func testPointSeed_TemplateKey() {
        let seed1 = PointSeed(bankName: "HSBC HK", pointName: "RC", pointValue: 1.25, valueCurrencyCode: .hk)
        let seed2 = PointSeed(bankName: "hsbc hk", pointName: "rc", pointValue: 1.25, valueCurrencyCode: .hk)

        // templateKey 应归一化大小写
        XCTAssertEqual(seed1.templateKey, seed2.templateKey)
    }

    // MARK: - 3. syncDefaultPoints 测试

    func testSyncDefaultPoints_InsertNew() throws {
        // 空库，同步所有默认积分
        try Point.syncDefaultPoints(in: context)

        let allPoints = try context.fetch(FetchDescriptor<Point>())
        XCTAssertEqual(allPoints.count, Point.defaultSeeds.count)
    }

    func testSyncDefaultPoints_PreservesUserModifiedValue() throws {
        // 先插入一个默认积分但值不同（模拟用户手动修改过估值）
        let seed = Point.defaultSeeds[0]
        let existingPoint = Point(
            bankName: seed.bankName,
            pointName: seed.pointName,
            pointValue: 999.0, // 用户自定义值
            valueCurrencyCode: seed.valueCurrencyCode
        )
        context.insert(existingPoint)
        try context.save()

        // 同步不应覆盖用户修改过的值
        try Point.syncDefaultPoints(in: context)

        let allPoints = try context.fetch(FetchDescriptor<Point>())
        let point = allPoints.first { $0.bankName == seed.bankName && $0.pointName == seed.pointName }
        XCTAssertEqual(point?.pointValue, 999.0, "同步不应覆盖用户自定义的积分估值")
    }

    func testSyncDefaultPoints_Idempotent() throws {
        try Point.syncDefaultPoints(in: context)
        let count1 = try context.fetch(FetchDescriptor<Point>()).count

        try Point.syncDefaultPoints(in: context)
        let count2 = try context.fetch(FetchDescriptor<Point>()).count

        XCTAssertEqual(count1, count2, "重复同步不应创建重复记录")
    }

    // MARK: - 4. 积分封顶逻辑测试

    func testPointsCapWithHistory() {
        let point = makePoint(pointValue: 0.01)
        // 基础 1x 积分率，baseCap = 500 积分
        let card = makeCard(defaultRate: 1.0, localBaseCap: 500, rewardType: .points, pointProgram: point)
        let now = Date()

        // 历史消费 300 → 基础 300 积分，剩余额度 200
        _ = makeTransaction(card: card, amount: 300, category: .other, date: now)

        // 新消费 400 → 理论 400 积分，但只剩 200
        let result = card.calculateCappedPoints(
            amount: 400, category: .other, location: .hk, date: now,
            paymentMethod: .offline, pointValueInCardCurrency: 0.01, transactionToExclude: nil
        )
        XCTAssertEqual(result.points, 200)
    }

    func testPointsCategoryCapTriggered() {
        let point = makePoint(pointValue: 0.01)
        // 基础 1x + 餐饮加成 4x, 类别上限 100 积分
        let card = makeCard(defaultRate: 1.0, specialRates: [.dining: 4.0], categoryCaps: [.dining: 100], rewardType: .points, pointProgram: point)

        // 消费 50：基础 50 + 餐饮(50*4=200 → 封顶100) = 150
        let result = card.calculateCappedPoints(
            amount: 50, category: .dining, location: .hk, date: Date(),
            paymentMethod: .offline, pointValueInCardCurrency: 0.01, transactionToExclude: nil
        )
        XCTAssertEqual(result.points, 150)
    }

    func testPointsPaymentCapTriggered() {
        let point = makePoint(pointValue: 0.01)
        // 基础 1x + Apple Pay 加成 3x, 支付上限 60 积分
        let card = makeCard(defaultRate: 1.0, paymentMethodRates: [.applePay: 3.0], paymentCaps: [.applePay: 60], rewardType: .points, pointProgram: point)

        // 消费 100：基础 100 + 支付(100*3=300 → 封顶60) = 160
        let result = card.calculateCappedPoints(
            amount: 100, category: .other, location: .hk, date: Date(),
            paymentMethod: .applePay, pointValueInCardCurrency: 0.01, transactionToExclude: nil
        )
        XCTAssertEqual(result.points, 160)
    }

    func testPointsZeroPointValue() {
        let point = makePoint(pointValue: 0.0)
        let card = makeCard(defaultRate: 1.0, rewardType: .points, pointProgram: point)

        let result = card.calculateCappedPoints(
            amount: 100, category: .other, location: .hk, date: Date(),
            paymentMethod: .offline, pointValueInCardCurrency: 0.0, transactionToExclude: nil
        )
        XCTAssertEqual(result.points, 0)
        XCTAssertEqual(result.value, 0.0)
    }

    func testPointsValue_Calculation() {
        let point = makePoint(pointValue: 0.01)
        let card = makeCard(defaultRate: 1.0, rewardType: .points, pointProgram: point)

        // 消费 100 → 100 积分 × 0.01 = 1.0
        let result = card.calculateCappedPoints(
            amount: 100, category: .other, location: .hk, date: Date(),
            paymentMethod: .offline, pointValueInCardCurrency: 0.01, transactionToExclude: nil
        )
        XCTAssertEqual(result.points, 100)
        XCTAssertEqual(result.value, 1.0, accuracy: 0.0001)
    }
}
