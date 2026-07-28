import XCTest
@testable import CashbackCounter

private typealias Category = CashbackCounter.Category

/// 分类映射与收支分流的规则。
///
/// 这些规则直接决定算出来的返现对不对，而错了几乎都是**静默**的 ——
/// 用户看到的是一个数字，不会知道它是怎么来的。所以每条都用测试钉住。
final class PlaidCategoryMappingTests: XCTestCase {

    // MARK: - detailed 优先于 primary

    /// 超市和餐厅的 primary 都是 FOOD_AND_DRINK，而多数卡对这两者费率完全不同。
    /// 只看 primary 的话，每一笔超市消费都会按餐饮费率算错。
    func testGroceriesAndRestaurantSplitByDetailed() {
        XCTAssertEqual(
            PlaidCategoryMapping.category(primary: "FOOD_AND_DRINK",
                                          detailed: "FOOD_AND_DRINK_GROCERIES"),
            .grocery)

        XCTAssertEqual(
            PlaidCategoryMapping.category(primary: "FOOD_AND_DRINK",
                                          detailed: "FOOD_AND_DRINK_RESTAURANT"),
            .dining)
    }

    func testDetailedMapsElectronicsAndStreaming() {
        XCTAssertEqual(
            PlaidCategoryMapping.category(primary: "GENERAL_MERCHANDISE",
                                          detailed: "GENERAL_MERCHANDISE_ELECTRONICS"),
            .digital)

        XCTAssertEqual(
            PlaidCategoryMapping.category(primary: "ENTERTAINMENT",
                                          detailed: "ENTERTAINMENT_TV_AND_MOVIES"),
            .streaming)
    }

    /// detailed 认不出来时退回 primary，再认不出来落 .other。
    /// 宁可用默认费率算出一个偏低的数，也不要凭空按高档位多算。
    func testFallsBackToPrimaryThenOther() {
        XCTAssertEqual(
            PlaidCategoryMapping.category(primary: "TRANSPORTATION",
                                          detailed: "TRANSPORTATION_TAXIS_AND_RIDE_SHARES"),
            .travel)

        XCTAssertEqual(
            PlaidCategoryMapping.category(primary: "GENERAL_MERCHANDISE",
                                          detailed: "GENERAL_MERCHANDISE_GIFTS_AND_NOVELTIES"),
            .other)

        XCTAssertEqual(PlaidCategoryMapping.category(primary: nil, detailed: nil), .other)
    }

    // MARK: - 流出：哪些不是消费

    /// 支持绑定银行账户之后最关键的一条。
    ///
    /// 信用卡上"还款"是负数，走流入分支就挡住了；但在银行账户上它是**正数**。
    /// 不挡的话，一笔信用卡还款会被当成消费入库并算出凭空的返现，
    /// 而那笔钱对应的真实消费已经从信用卡那边同步过一遍了 —— 同一笔钱算两次。
    func testCreditCardPaymentFromBankAccountIsNotAPurchase() {
        // 还款按 primary 就能确定，不需要 detailed
        XCTAssertTrue(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "LOAN_PAYMENTS", detailed: "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"))
        XCTAssertTrue(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "LOAN_PAYMENTS", detailed: nil))
    }

    /// 自己账户之间搬钱会造成双重计算，必须挡
    func testSelfTransfersAreNotPurchases() {
        XCTAssertTrue(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "TRANSFER_OUT", detailed: "TRANSFER_OUT_ACCOUNT_TRANSFER"))
        XCTAssertTrue(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "TRANSFER_OUT", detailed: "TRANSFER_OUT_SAVINGS"))
        // ATM 取现不产生任何奖励
        XCTAssertTrue(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "TRANSFER_OUT", detailed: "TRANSFER_OUT_WITHDRAWAL"))
    }

    /// **回归测试**：AlipayHK / PayPal / Venmo 这类钱包支付的 primary 是 TRANSFER_OUT，
    /// 但它们是真实消费。按 primary 一刀切会让这些交易**静默消失** ——
    /// 而这正是用户最不可能发现的那类错误。
    func testWalletPaymentsAreStillPurchases() {
        // 真实线上数据：AlipayHK 付款就是这个值。
        // ⚠️ 它**不在** Plaid 官方公布的分类表 CSV 里 —— 说明这套分类会在文档之外扩充，
        // 所以判定必须是"排除名单 + 未知一律当消费"，不能反过来做成白名单。
        XCTAssertFalse(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "TRANSFER_OUT", detailed: "TRANSFER_OUT_TRANSFER_OUT_FROM_APPS"))

        XCTAssertFalse(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "TRANSFER_OUT", detailed: "TRANSFER_OUT_OTHER_TRANSFER_OUT"))

        // detailed 缺失时也当消费：分不清就选看得见的那个方向
        XCTAssertFalse(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "TRANSFER_OUT", detailed: nil))

        // 未来 Plaid 再加新的转账子类，也必须默认放行
        XCTAssertFalse(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "TRANSFER_OUT", detailed: "TRANSFER_OUT_SOMETHING_PLAID_ADDS_LATER"))
    }

    /// 年费、手续费是账单上真实存在的支出，挡掉合计就和账单对不上了
    func testBankFeesAreStillPurchases() {
        XCTAssertFalse(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "BANK_FEES", detailed: "BANK_FEES_ANNUAL_FEES"))
    }

    func testNormalSpendingIsAPurchase() {
        XCTAssertFalse(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "FOOD_AND_DRINK", detailed: "FOOD_AND_DRINK_RESTAURANT"))
        XCTAssertFalse(PlaidCategoryMapping.isNonPurchaseOutflow(
            primary: "TRAVEL", detailed: "TRAVEL_FLIGHTS"))
        XCTAssertFalse(PlaidCategoryMapping.isNonPurchaseOutflow(primary: nil, detailed: nil))
    }

    // MARK: - 流入：哪些不是退款

    /// 负数 ≠ 退款。误判成退款会去**删掉**一笔金额相等的真实消费。
    func testPaymentsAndTransfersAreNotRefunds() {
        XCTAssertTrue(PlaidCategoryMapping.isNonRefundInflow(primary: "LOAN_PAYMENTS"))
        XCTAssertTrue(PlaidCategoryMapping.isNonRefundInflow(primary: "TRANSFER_IN"))
        XCTAssertTrue(PlaidCategoryMapping.isNonRefundInflow(primary: "INCOME"))
        // 分类缺失时保守处理成"不是退款"：漏掉一笔真退款只是多留一条记录，
        // 用户能自己删；误删一笔真实消费用户很可能永远发现不了
        XCTAssertTrue(PlaidCategoryMapping.isNonRefundInflow(primary: nil))
    }

    func testMerchantInflowIsARefund() {
        XCTAssertFalse(PlaidCategoryMapping.isNonRefundInflow(primary: "TRAVEL"))
        XCTAssertFalse(PlaidCategoryMapping.isNonRefundInflow(primary: "FOOD_AND_DRINK"))
    }

    // MARK: - 消费方式

    func testPaymentChannelMapping() {
        XCTAssertEqual(PlaidCategoryMapping.paymentMethod(from: "online"), .online)
        XCTAssertEqual(PlaidCategoryMapping.paymentMethod(from: "in store"), .offline)
        XCTAssertEqual(PlaidCategoryMapping.paymentMethod(from: "other"), .offline)
        XCTAssertEqual(PlaidCategoryMapping.paymentMethod(from: nil), .offline)
    }
}
