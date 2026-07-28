import SwiftUI
import SwiftData

/// 这笔交易是怎么进来的。
///
/// 存在的唯一理由：**同步引擎的去重、退款抵销、清理，全都只能作用于 `.plaid` 的记录**。
/// 手动记的账是用户亲手输入的，任何自动逻辑都无权碰它 —— 被算法删掉一笔自己记的账
/// 是不可接受的，而且用户根本不会知道发生了什么。
enum TransactionSource: String, Codable, CaseIterable {
    /// 用户手动录入 / 拍照 / 短信 / CSV 导入
    case manual
    /// 由 Plaid 银行同步自动导入
    case plaid
}

@Model
class Transaction: Identifiable {
    var merchant: String = ""
    var category: Category = Category.other
    var location: Region = Region.cn
    
    var amount: Double = 0.0        // 原币金额
    var billingAmount: Double = 0.0 // 入账金额
    // 入账币种代码 (如 "CNY"/"HKD")；nil = 旧数据，读取时走 resolvedBillingCurrencyCode 启发式
    var billingCurrencyCode: String? = nil
    
    var date: Date = Date()
    var cashbackamount: Double = 0.0
    var pointsEarned: Int = 0
    var rate: Double = 0.0
    
    var card: CreditCard?
    
    // 👇 1. 新增字段：记录消费方式 (Apple Pay, 线下等)
    var paymentMethod: PaymentMethod = PaymentMethod.offline

    /// 数据来源。有默认值，SwiftData 走轻量迁移，历史数据自动落到 .manual —— 正确，
    /// 因为这个字段出现之前的每一笔都确实是手动记的。
    var source: TransactionSource = TransactionSource.manual

    @Attribute(.externalStorage) var receiptData: Data?
    
    @Relationship(deleteRule: .cascade, inverse: \Income.transaction)
    var incomes: [Income]?
    
    // 👇 2. 更新构造函数
    init(merchant: String,
         category: Category,
         location: Region,
         amount: Double,
         date: Date,
         card: CreditCard?,
         receiptData: Data? = nil,
         billingAmount: Double? = nil,
         cashbackAmount: Double? = nil,
         pointsEarned: Int = 0,
         // 新增参数：设置默认值 .offline，这样旧代码不需要改动即可编译
         paymentMethod: PaymentMethod = .offline,
         billingCurrencyCode: String? = nil,
         // 同样给默认值：所有既有调用点都是手动记账，一处都不用改
         source: TransactionSource = .manual
    ) {
        self.merchant = merchant
        self.category = category
        self.location = location
        self.amount = amount
        self.date = date
        self.card = card
        self.receiptData = receiptData
        self.billingAmount = billingAmount ?? amount
        self.billingCurrencyCode = billingCurrencyCode
            ?? card?.billingRegion(for: location).currencyCode
            ?? location.currencyCode

        // 赋值
        self.paymentMethod = paymentMethod
        self.source = source

        let finalBilling = billingAmount ?? amount
        
        // 计算名义费率
        // 注意：如果你后续更新了 CreditCard.getRate 支持 paymentMethod，这里也要跟着改
        // 目前先保持原逻辑，避免报错
        let nominalRate = card?.getRate(for: category, location: location, payment: paymentMethod) ?? 0
        
        if let providedCashback = cashbackAmount {
            self.cashbackamount = providedCashback
            // 防止 finalBilling 为 0（如 CSV 导入解析失败）时产生 NaN
            self.rate = finalBilling != 0 ? (providedCashback / finalBilling * 100).rounded() / 100 : 0
        } else {
            self.cashbackamount = finalBilling * nominalRate
            self.rate = nominalRate
        }

        self.pointsEarned = pointsEarned
    }
    
    var color: Color { category.color }
    private static let _dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var dateString: String {
        Self._dateFormatter.string(from: date)
    }
}

extension Transaction {
    /// 交易入账币种；旧数据 (nil) 走启发式推断
    var resolvedBillingCurrencyCode: String {
        if let code = billingCurrencyCode, !code.isEmpty {
            return code
        }
        guard let card else { return location.currencyCode }
        // 旧数据导入：billingAmount 未换汇时按消费地币种入账
        if location != card.issueRegion, abs(billingAmount - amount) < 0.0001 {
            return location.currencyCode
        }
        // 用 billingRegion(for:) 而非 issueRegion，这样卡片后来升级为双币卡时旧交易也能正确归类
        return card.billingRegion(for: location).currencyCode
    }
}
