//
//  PlaidModels.swift
//  CashbackCounter
//
//  和后端交换的数据结构。字段名与后端的 record 逐字对应 ——
//  两边任何一边改名都必须同时改另一边，没有中间层能吸收这个变化。
//

import Foundation

// MARK: - 交易

/// 对应后端 `TransactionService.TransactionView`
struct PlaidTransactionDTO: Decodable {

    let accountId: String
    let accountName: String?
    let accountMask: String?

    /// `yyyy-MM-dd`。后端是 LocalDate，Jackson 按 ISO 输出，不带时区
    let date: String

    /// 银行报的原始描述，通常很脏（"SQ *BLUE BOTTLE COFFEE 123"）
    let name: String?
    /// Plaid 清洗过的商户名，有就优先用
    let merchantName: String?

    /// ⚠️ **正数表示资金流出（消费），负数表示流入（退款、还款、收入）**。
    /// 这是 Plaid 的符号约定，和直觉相反，整个同步引擎都建立在它之上。
    let amount: Double

    /// 结算币种。⚠️ 是**结算后**的，不是原始消费币种 ——
    /// 美国的卡在日本刷日元，这里只有 USD
    let currency: String?

    /// 待处理。金额会变、日期会移，所以一律不入库
    let pending: Bool

    /// PFC primary，如 `FOOD_AND_DRINK`
    let category: String?
    /// PFC detailed，如 `FOOD_AND_DRINK_GROCERIES`
    let categoryDetailed: String?

    /// `online` / `in store` / `other`
    let paymentChannel: String?
}

extension PlaidTransactionDTO {

    /// 展示用的商户名。Plaid 清洗过的优先，都没有就退回一个不至于空着的占位。
    var resolvedMerchant: String {
        if let merchantName, !merchantName.isEmpty { return merchantName }
        if let name, !name.isEmpty { return name }
        return "未知商户"
    }

    /// 解析日期。用固定的 POSIX 格式器 ——
    /// 用户设备可能是非公历日历（如日本和历、佛历），
    /// 那种情况下默认 Calendar 解析 "2026-07-27" 会得到完全错误的日期。
    var parsedDate: Date? {
        Self.dateFormatter.date(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        // 固定 POSIX locale + 公历：用户设备可能是非公历日历（日本和历、佛历），
        // 那种情况下默认 Calendar 解析 "2026-07-27" 会得到完全错误的日期。
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        // ⚠️ 有意**不设** timeZone，用系统默认（本地时区）。
        //
        // Plaid 的 date 是一个纯日历日期，不带时区 —— 它就是账单上印的那一天。
        // 按 UTC 午夜解析的话，在美国（UTC-5 ~ -8）会变成前一天的下午，
        // 之后 startOfDay 一取就整体退一天：一笔 7/27 的消费会显示成 7/26。
        // 而这个 App 的用户拿的正是美国的卡，全都会中招。
        return f
    }()

    /// 是否是资金流入（退款 / 还款 / 收入）
    var isInflow: Bool { amount < 0 }

    /// 绝对金额，单位是分。
    ///
    /// 去重按整数分比较而不是 Double ——
    /// 12.34 这样的值用二进制浮点存不精确，两笔"相同"金额直接 == 有可能为 false，
    /// 那样去重就会漏，表现为每次同步都多出一批重复交易。
    var amountCents: Int {
        Int((abs(amount) * 100).rounded())
    }
}

// MARK: - 账户

/// 对应后端 `PlaidService.AccountView`
struct PlaidAccountDTO: Decodable {
    let accountId: String
    let name: String?
    let officialName: String?
    /// 账户尾号，自动匹配卡片就靠它
    let mask: String?
    let type: String?
    let subtype: String?
    /// 信用卡这里是已用额度（欠款）
    let currentBalance: Double?
    let availableBalance: Double?
    let creditLimit: Double?
    let currency: String?
}

// MARK: - 绑定流程

struct LinkTokenResponse: Decodable {
    let linkToken: String

    enum CodingKeys: String, CodingKey {
        case linkToken = "link_token"
    }
}

struct ExchangeRequest: Encodable {
    let publicToken: String

    enum CodingKeys: String, CodingKey {
        case publicToken = "public_token"
    }
}

struct ExchangeResponse: Decodable {
    let status: String
    let itemId: String

    enum CodingKeys: String, CodingKey {
        case status
        case itemId = "item_id"
    }
}

struct LinkedItemDTO: Decodable {
    let itemId: String
    let institutionName: String
    let linkedAt: String
}

struct UnlinkResponse: Decodable {
    let status: String
    let itemId: String

    enum CodingKeys: String, CodingKey {
        case status
        case itemId = "item_id"
    }
}
