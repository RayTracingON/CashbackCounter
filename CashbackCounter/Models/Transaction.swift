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

    /// 建档时生成一次的稳定标识。**交易去重只认它，不认内容。**
    ///
    /// 按 (商户, 日期, 金额) 这类内容指纹去重是错的：同一天在同一家店买两杯一样的咖啡
    /// 就是两笔内容完全相同的真实交易，按内容去重会把第二杯永久删掉 ——
    /// 而且用户看不出来。同步引擎的数量对齐（见 PlaidSyncService.insertWithCountAlignment）
    /// 早就为这件事绕过路，本地去重不能再踩回去。
    ///
    /// CloudKit 重新导入产生的重复记录会**连这个字段一起复制**，所以它们共享同一个值，
    /// 能被可靠识别；两杯咖啡拿到的是两个不同的 UUID，永远不会被合并。
    ///
    /// 默认空串是为了让 SwiftData 走轻量迁移。空串 = 该字段出现之前的旧数据，
    /// 由 CardTemplateManager 在去重时就地补一个 UUID（见那里的注释）。
    ///
    /// ⚠️ **这是新增字段，发版前必须在 CloudKit Dashboard 把 schema 部署到 Production。**
    /// 加字段是 CloudKit 允许的增量改动（不像改类型/改名），但 Production 环境
    /// **不会自动建字段** —— 漏了这一步，线上包导出记录时会因为字段不存在而报错，
    /// 整条 iCloud 同步链路停摆。
    ///
    /// 混合版本（部分用户还在旧版）是安全的，靠的是"空串永不参与删除"这条规则：
    ///   · 旧版建的记录没有这个字段 → 新版读到空串 → 补 UUID → 只形成单元素分组
    ///   · 旧版编辑记录时可能把这个字段抹掉 → 同样回落到空串
    /// 两种情况的后果都只是"某次重复没被合并"，而不是"删错了一笔"。
    /// 这个方向是刻意选的：多一笔用户看得见也能自己删，少一笔看不见也救不回来。
    var dedupeID: String = ""

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
        self.dedupeID = UUID().uuidString

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
