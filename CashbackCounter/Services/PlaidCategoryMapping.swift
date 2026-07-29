//
//  PlaidCategoryMapping.swift
//  CashbackCounter
//
//  Plaid 的分类体系 → 本 App 的 Category。
//
//  这张表直接决定算出来的返现对不对：Category 是费率引擎的输入，
//  映射错一档，金额就错一档。所以宁可保守 —— **拿不准就落 .other**，
//  用默认费率算出一个偏低但不离谱的数，好过按"超市 5%"算出一个凭空多出来的数字。
//

import Foundation

extension CreditCard {

    /// 一点积分折算成**发卡币种**的价值。
    ///
    /// 积分计划的估值币种和卡的发卡地可以不同（比如 Amex HK 的积分按 HKD 估值，
    /// 但卡是美国发的），这时要按汇率换算一次，否则算出来的返现价值差一个汇率倍数。
    ///
    /// ⚠️ 同样的逻辑在 AddTransactionViewModel 和 AddTransactionFromScreenshotIntent
    /// 里各有一份拷贝。这里没有去动那两处（它们在正常工作，改动有风险），
    /// 但三份实现必须保持一致 —— 将来重构时应该都收敛到这个方法。
    func pointValueInCardCurrency() async -> Double {
        guard let pointProgram else { return 0 }

        let pointRegion = pointProgram.valueCurrencyCode
        if pointRegion == issueRegion {
            return pointProgram.pointValue
        }

        let rates = await CurrencyService.getRates(base: pointRegion.currencyCode)
        if let rate = rates[issueRegion.currencyCode], rate > 0 {
            return pointProgram.pointValue * rate
        }
        // 拿不到汇率时退回未换算的值：偏差好过算出 0
        return pointProgram.pointValue
    }
}

enum PlaidCategoryMapping {

    /// Plaid 的 PFC 是两级：primary（16 个大类）+ detailed（100 多个细类）。
    ///
    /// **必须优先看 detailed**：超市和餐厅的 primary 都是 FOOD_AND_DRINK，
    /// 而多数信用卡对这两者的费率完全不同。只看 primary 的话，
    /// 每一笔超市消费都会被按餐饮费率算错。
    static func category(primary: String?, detailed: String?) -> Category {
        if let detailed, let mapped = fromDetailed(detailed.uppercased()) {
            return mapped
        }
        return fromPrimary(primary?.uppercased())
    }

    // MARK: - detailed（优先）

    private static func fromDetailed(_ detailed: String) -> Category? {
        switch detailed {

        // 超市 / 便利店 —— 独立成档的主要理由
        case "FOOD_AND_DRINK_GROCERIES",
             "GENERAL_MERCHANDISE_CONVENIENCE_STORES",
             "GENERAL_MERCHANDISE_SUPERSTORES":
            return .grocery

        // 餐饮
        case "FOOD_AND_DRINK_RESTAURANT",
             "FOOD_AND_DRINK_FAST_FOOD",
             "FOOD_AND_DRINK_COFFEE",
             "FOOD_AND_DRINK_BEER_WINE_AND_LIQUOR",
             "FOOD_AND_DRINK_VENDING_MACHINES",
             "FOOD_AND_DRINK_OTHER_FOOD_AND_DRINK":
            return .dining

        // 订阅。ENTERTAINMENT 大类里只有这一档属于"订阅"，
        // 演唱会门票、电影票走 .other
        case "ENTERTAINMENT_TV_AND_MOVIES",
             "ENTERTAINMENT_MUSIC_AND_AUDIO",
             "GENERAL_SERVICES_SUBSCRIPTIONS":
            return .streaming

        // 数码
        case "GENERAL_MERCHANDISE_ELECTRONICS",
             "GENERAL_MERCHANDISE_OFFICE_SUPPLIES":
            return .digital

        // 二次元没有对应的 Plaid 分类（那是中文互联网的概念，
        // 不是消费数据里的一个维度）。永远落不到这一档，只能靠用户手动改。
        default:
            return nil
        }
    }

    // MARK: - primary（兜底）

    private static func fromPrimary(_ primary: String?) -> Category {
        switch primary {
        case "FOOD_AND_DRINK":
            // detailed 缺失时的保守选择：餐饮通常比超市档位低，
            // 宁可少算不要多算
            return .dining
        case "TRAVEL", "TRANSPORTATION":
            return .travel
        default:
            return .other
        }
    }

    // MARK: - 收支分流

    /// 负数金额里哪些**不是退款**。
    ///
    /// 负数 ≠ 退款，这是这套逻辑最容易错的地方：给信用卡还款是负数、
    /// 账单调整是负数、银行返还的年费也是负数。把它们当退款处理，
    /// 就会去删掉一笔金额恰好相等的正常消费 —— 用户的账目凭空少一笔，
    /// 而且没有任何提示。
    static func isNonRefundInflow(primary: String?) -> Bool {
        guard let primary = primary?.uppercased() else {
            // 分类缺失时按"不是退款"处理。
            // 保守方向的选择：漏掉一笔真退款只是多留一条记录，用户能自己删；
            // 误判一笔还款为退款则会删掉一笔真实消费，用户很可能永远发现不了。
            return true
        }
        return nonRefundPrimaries.contains(primary)
    }

    /// 正数金额里哪些**不是消费**。
    ///
    /// 支持绑定银行活期/储蓄账户之后才需要这一条，而且它是必须的：
    /// 在信用卡上，"还款"表现为**负数**（冲减欠款），走上面的流入分支就挡住了；
    /// 但在银行账户上，同一笔还款是**正数**（钱流出账户）。
    /// 不挡的话，一笔 2000 元的信用卡还款会被当成 2000 元消费入库、
    /// 还按费率算出一笔凭空的返现 —— 而那 2000 元对应的真实消费，
    /// 已经从信用卡那边同步过一遍了。**同一笔钱被算了两次**。
    ///
    /// 同理，自己账户之间的转账（TRANSFER_OUT）也不是消费。
    ///
    /// 注意 `BANK_FEES` **不在**这个名单里：年费、ATM 手续费是账单上真实存在的支出，
    /// 挡掉它 App 里的合计就和账单对不上了。它算出的那点返现有偏差，
    /// 但那是**看得见、能手动改**的偏差；而少一笔支出用户根本发现不了。
    ///
    /// ⚠️ **`TRANSFER_*` 必须看 detailed，不能按 primary 一刀切。**
    /// 这一层里混着两类完全不同的东西：一类是"自己账户之间搬钱"（该挡），
    /// 另一类是"用第三方钱包真实消费"——AlipayHK、PayPal、Venmo 付款
    /// 都会落到 `TRANSFER_OUT_OTHER_TRANSFER_OUT`。
    /// 按 primary 挡掉的话，所有钱包支付会**静默消失**，
    /// 而这正是用户最不可能发现的那类错误。
    static func isNonPurchaseOutflow(primary: String?, detailed: String?) -> Bool {
        let primary = primary?.uppercased()

        // 无条件排除：还款（信用卡/贷款）是双重计算的主要来源，
        // 因为那笔钱对应的真实消费已经从信用卡那边同步过一遍了。
        if primary == "LOAN_PAYMENTS" || primary == "INCOME" {
            return true
        }

        guard primary == "TRANSFER_OUT" || primary == "TRANSFER_IN" else {
            return false
        }

        // detailed 缺失时按"是消费"处理。
        // 和别处一样的取舍：多留一条看得见的记录，好过静默丢掉一笔真实支出。
        guard let detailed = detailed?.uppercased() else { return false }
        return unambiguousTransferDetails.contains(detailed)
    }

    /// 只有能**确定**不是消费的转账子类才列在这里，其余一律放行。
    ///
    /// 必须是"排除名单"而不是"白名单"：Plaid 的分类表会在官方 CSV 之外扩充
    /// （实测 `TRANSFER_OUT_TRANSFER_OUT_FROM_APPS` 就没被文档收录，
    /// 但真实数据里有）。做成白名单的话，每次 Plaid 加一个新子类，
    /// 对应的交易就会静默消失；做成排除名单，最坏也只是多出一条看得见的记录。
    ///
    /// 刻意不含的两个：
    ///   · `TRANSFER_OUT_OTHER_TRANSFER_OUT`
    ///   · `TRANSFER_OUT_TRANSFER_OUT_FROM_APPS` —— AlipayHK / PayPal / Venmo 等
    ///     钱包支付的落点，那是真实消费
    private static let unambiguousTransferDetails: Set<String> = [
        "TRANSFER_OUT_ACCOUNT_TRANSFER",                  // 自己账户之间
        "TRANSFER_OUT_SAVINGS",                           // 转进储蓄
        "TRANSFER_OUT_INVESTMENT_AND_RETIREMENT_FUNDS",   // 转进投资账户
        "TRANSFER_OUT_WITHDRAWAL",                        // ATM 取现，不产生奖励
        "TRANSFER_IN_ACCOUNT_TRANSFER",
        "TRANSFER_IN_SAVINGS",
        "TRANSFER_IN_INVESTMENT_AND_RETIREMENT_FUNDS",
        "TRANSFER_IN_DEPOSIT",
        "TRANSFER_IN_CASH_ADVANCES_AND_LOANS"
    ]

    private static let nonRefundPrimaries: Set<String> = [
        "LOAN_PAYMENTS",   // 还信用卡 / 贷款
        "TRANSFER_IN",     // 转入
        "TRANSFER_OUT",
        "BANK_FEES",       // 费用冲正
        "INCOME"           // 工资、利息
    ]


    // MARK: - 消费方式

    /// Plaid 的 payment_channel → 本 App 的 PaymentMethod。
    ///
    /// 只区分线上/线下。Apple Pay 这类信息 Plaid 不提供 ——
    /// 它拿到的是银行的交易记录，而银行那边看到的就是一笔普通的卡交易。
    static func paymentMethod(from channel: String?) -> PaymentMethod {
        switch channel?.lowercased() {
        case "online":
            return .online
        default:
            // "in store" 和 "other" 都落线下。
            // other 多数是银行没标清楚的实体消费。
            return .offline
        }
    }
}
