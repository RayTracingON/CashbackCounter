import XCTest
import SwiftUI
import SwiftData
@testable import CashbackCounter

private typealias Category = CashbackCounter.Category
private typealias Transaction = CashbackCounter.Transaction

final class ServiceTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

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
        bankName: String = "TestBank",
        type: String = "TestCard",
        endNum: String = "1234",
        defaultRate: Double = 0.01,
        specialRates: [Category: Double] = [:],
        issueRegion: Region = .hk,
        paymentMethodRates: [PaymentMethod: Double] = [:]
    ) -> CreditCard {
        let card = CreditCard(
            bankName: bankName, type: type, endNum: endNum,
            colorHexes: ["FF0000"], defaultRate: defaultRate,
            specialRates: specialRates, issueRegion: issueRegion,
            paymentMethodRates: paymentMethodRates
        )
        context.insert(card)
        return card
    }

    private func makeTransaction(
        card: CreditCard,
        merchant: String = "Test Merchant",
        amount: Double = 100.0,
        category: Category = .dining,
        location: Region = .hk,
        paymentMethod: PaymentMethod = .offline,
        cashbackAmount: Double? = nil
    ) -> Transaction {
        let tx = Transaction(
            merchant: merchant,
            category: category,
            location: location,
            amount: amount,
            date: Date(),
            card: card,
            cashbackAmount: cashbackAmount,
            paymentMethod: paymentMethod
        )
        context.insert(tx)
        return tx
    }

    // MARK: - 1. CashbackService 测试

    func testCashbackService_CalculateCashback() {
        let card = makeCard(defaultRate: 0.05)
        let tx = makeTransaction(card: card, amount: 100, cashbackAmount: 5.0)

        let cashback = CashbackService.calculateCashback(for: tx)
        XCTAssertEqual(cashback, 5.0, accuracy: 0.0001)
    }

    func testCashbackService_GetCardName_HasCard() {
        let card = makeCard(bankName: "HSBC", type: "Visa Platinum")
        let tx = makeTransaction(card: card)

        let name = CashbackService.getCardName(for: tx)
        XCTAssertEqual(name, "HSBC Visa Platinum")
    }

    func testCashbackService_GetCardName_NoCard() {
        let card = makeCard()
        let tx = makeTransaction(card: card)
        tx.card = nil

        let name = CashbackService.getCardName(for: tx)
        XCTAssertEqual(name, "已删除卡片")
    }

    func testCashbackService_GetCardNum_HasCard() {
        let card = makeCard(endNum: "9876")
        let tx = makeTransaction(card: card)

        let num = CashbackService.getCardNum(for: tx)
        XCTAssertEqual(num, "9876")
    }

    func testCashbackService_GetCardNum_NoCard() {
        let card = makeCard()
        let tx = makeTransaction(card: card)
        tx.card = nil

        let num = CashbackService.getCardNum(for: tx)
        XCTAssertEqual(num, "已删除卡片")
    }

    func testCashbackService_GetCurrency() {
        let card = makeCard()
        let tx = makeTransaction(card: card, location: .us)

        let currency = CashbackService.getCurrency(for: tx)
        XCTAssertEqual(currency, "US$")
    }

    func testCashbackService_GetRate_HasCard() {
        let card = makeCard(defaultRate: 0.01, specialRates: [.dining: 0.05])
        let tx = makeTransaction(card: card, category: .dining)

        let rate = CashbackService.getRate(for: tx)
        XCTAssertEqual(rate, 0.06, accuracy: 0.0001)
    }

    func testCashbackService_GetRate_NoCard() {
        let card = makeCard()
        let tx = makeTransaction(card: card)
        tx.card = nil

        let rate = CashbackService.getRate(for: tx)
        XCTAssertEqual(rate, 0.0)
    }

    // MARK: - 2. String.toDate 测试

    func testStringToDate_Valid() {
        let dateStr = "2025-12-31"
        let date = dateStr.toDate()
        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.year, from: date), 2025)
        XCTAssertEqual(calendar.component(.month, from: date), 12)
        XCTAssertEqual(calendar.component(.day, from: date), 31)
    }

    func testStringToDate_InvalidFormat() {
        let dateStr = "not-a-date"
        let date = dateStr.toDate()
        // 非法字符串应返回今天
        let calendar = Calendar.current
        XCTAssertTrue(calendar.isDateInToday(date))
    }

    // MARK: - 3. CSV 导出测试

    func testCSVExport_HeaderFormat() {
        let transactions: [Transaction] = []
        let csv = transactions.generateCSV()

        XCTAssertTrue(csv.contains("交易时间"))
        XCTAssertTrue(csv.contains("商户名称"))
        XCTAssertTrue(csv.contains("消费类别"))
        XCTAssertTrue(csv.contains("支付方式"))
        XCTAssertTrue(csv.contains("积分数"))
    }

    func testCSVExport_RowContent() {
        let card = makeCard(bankName: "HSBC", type: "Visa", endNum: "5678", defaultRate: 0.01)
        let tx = makeTransaction(card: card, merchant: "McDonald's", amount: 50, category: .dining, location: .hk, paymentMethod: .applePay)

        let csv = [tx].generateCSV()
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 2, "Should have header + 1 data row")

        let dataRow = lines[1]
        XCTAssertTrue(dataRow.contains("McDonald's"), "应包含商户名")
        // 类别列导的是 rawValue 而不是显示名：显示名随界面语言变，换语言后导不回来
        XCTAssertTrue(dataRow.contains(",dining,"), "应包含类别 rawValue")
        XCTAssertTrue(dataRow.contains("5678"), "应包含卡号尾数")
        XCTAssertTrue(dataRow.contains("applePay"), "应包含支付方式")
    }

    func testCSVExport_MerchantQuoting() {
        let card = makeCard()
        let tx = makeTransaction(card: card, merchant: "McDonald's, \"Flagship\" Store")

        let csv = [tx].generateCSV()
        // 商户名含逗号和引号，应被引号包裹且内部引号转义
        XCTAssertTrue(csv.contains("\"McDonald's, \"\"Flagship\"\" Store\""), "商户名应正确转义")
    }

    // MARK: - 4. Card CSV 导出测试

    func testCardCSVExport_HeaderFormat() {
        let csv = CardCSVHelper.generateCSV(from: [])
        XCTAssertTrue(csv.contains("银行名称"))
        XCTAssertTrue(csv.contains("卡种名称"))
        XCTAssertTrue(csv.contains("支付方式加成"))
        XCTAssertTrue(csv.contains("奖励类型"))
        XCTAssertTrue(csv.contains("积分名称"))
    }

    func testCardCSVExport_BasicContent() {
        let card = makeCard(
            bankName: "HSBC", type: "Visa Platinum", endNum: "4321",
            defaultRate: 0.01, specialRates: [.dining: 0.05], issueRegion: .hk,
            paymentMethodRates: [.applePay: 0.02]
        )
        card.localBaseCap = 100
        card.capPeriod = .monthly

        let csv = CardCSVHelper.generateCSV(from: [card])
        XCTAssertTrue(csv.contains("HSBC"))
        XCTAssertTrue(csv.contains("Visa Platinum"))
        XCTAssertTrue(csv.contains("4321"))
        XCTAssertTrue(csv.contains("monthly"))
    }

    // MARK: - 5. FrankfurterLatestResponse 解码测试

    @MainActor func testFrankfurterResponse_Decode() throws {
        let json = """
        {
            "date": "2025-12-31",
            "CNY": {
                "USD": 0.14,
                "HKD": 1.08,
                "JPY": 21.5
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(FrankfurterLatestResponse.self, from: data)

        XCTAssertEqual(response.date, "2025-12-31")
        XCTAssertEqual(response.base, "CNY")
        XCTAssertEqual(response.rates["USD"], 0.14)
        XCTAssertEqual(response.rates["HKD"], 1.08)
        XCTAssertEqual(response.rates["JPY"], 21.5)
    }

    @MainActor func testFrankfurterResponse_DecodeEmptyRates() throws {
        let json = """
        {
            "date": "2025-01-01",
            "USD": {}
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(FrankfurterLatestResponse.self, from: data)

        XCTAssertEqual(response.base, "USD")
        XCTAssertTrue(response.rates.isEmpty)
    }

    // MARK: - 6. CachedRates Codable 测试

    @MainActor func testCachedRates_Codable() throws {
        let original = CachedRates(base: "CNY", rates: ["USD": 0.14, "HKD": 1.08])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedRates.self, from: data)

        XCTAssertEqual(decoded.base, original.base)
        XCTAssertEqual(decoded.rates["USD"], original.rates["USD"])
        XCTAssertEqual(decoded.rates["HKD"], original.rates["HKD"])
    }

    // MARK: - 7. Region / Category / PaymentMethod 枚举测试

    func testRegion_AllCases() {
        XCTAssertEqual(Region.allCases.count, 9)
        for region in Region.allCases {
            XCTAssertFalse(region.icon.isEmpty)
            XCTAssertFalse(region.currencySymbol.isEmpty)
            XCTAssertFalse(region.currencyCode.isEmpty)
        }
    }

    func testCategory_AllCases() {
        // 7 类：餐饮、超市、出行、数码、二次元、订阅、其他。加类别时同步改这里
        XCTAssertEqual(Category.allCases.count, 7)
        for cat in Category.allCases {
            XCTAssertFalse(cat.iconName.isEmpty)
            XCTAssertFalse(cat.displayName.isEmpty)
        }
    }

    func testPaymentMethod_AllCases() {
        XCTAssertEqual(PaymentMethod.allCases.count, 6)
        for pm in PaymentMethod.allCases {
            XCTAssertFalse(pm.iconName.isEmpty)
            XCTAssertFalse(pm.displayName.isEmpty)
        }
    }

    func testRewardType_AllCases() {
        XCTAssertEqual(RewardType.allCases.count, 2)
        XCTAssertEqual(RewardType.cashback.displayName, "返现")
        XCTAssertEqual(RewardType.points.displayName, "积分")
    }

    // MARK: - 8. Transaction 模型测试

    func testTransaction_DateString() {
        let card = makeCard()
        let date = "2025-06-15".toDate()
        let tx = makeTransaction(card: card)
        tx.date = date

        XCTAssertEqual(tx.dateString, "2025-06-15")
    }

    func testTransaction_ColorFromCategory() {
        let card = makeCard()
        let tx = makeTransaction(card: card, category: .dining)
        XCTAssertEqual(tx.color, Category.dining.color)
    }

    func testTransaction_BillingAmountDefault() {
        // 不传 billingAmount 时，应等于 amount
        let card = makeCard()
        let tx = Transaction(
            merchant: "Test", category: .other, location: .hk,
            amount: 123.45, date: Date(), card: card
        )
        XCTAssertEqual(tx.billingAmount, 123.45, accuracy: 0.0001)
    }

    // MARK: - 9. Income 模型测试

    func testIncome_DateString() {
        let income = Income(amount: 10, date: "2025-03-20".toDate(), location: .hk)
        context.insert(income)
        XCTAssertEqual(income.dateString, "2025-03-20")
    }

    func testIncome_Defaults() {
        let income = Income(amount: 50, date: Date(), location: .cn)
        XCTAssertEqual(income.detail, "")
        XCTAssertEqual(income.platform, "")
        XCTAssertFalse(income.isReceived)
        XCTAssertNil(income.transaction)
    }

    // MARK: - 10. Color(hex:) Extension 测试

    func testColorHex_6Digit() {
        let color = Color(hex: "FF0000")
        // 无法直接比较 Color 的 RGB，但确保不崩溃
        XCTAssertNotNil(color)
    }

    func testColorHex_3Digit() {
        let color = Color(hex: "F00")
        XCTAssertNotNil(color)
    }

    func testColorHex_8Digit() {
        let color = Color(hex: "FF00FF00")
        XCTAssertNotNil(color)
    }

    func testColorHex_Invalid() {
        let color = Color(hex: "ZZZZZZ")
        XCTAssertNotNil(color) // 应不崩溃，使用 fallback
    }
}
