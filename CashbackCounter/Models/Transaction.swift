import SwiftUI
import SwiftData

@Model
class Transaction: Identifiable {
    var merchant: String = ""
    var category: Category = Category.other
    var location: Region = Region.cn
    
    var amount: Double = 0.0        // 原币金额
    var billingAmount: Double = 0.0 // 入账金额
    
    var date: Date = Date()
    var cashbackamount: Double = 0.0
    var pointsEarned: Int = 0
    var rate: Double = 0.0
    
    var card: CreditCard?
    
    // 👇 1. 新增字段：记录消费方式 (Apple Pay, 线下等)
    var paymentMethod: PaymentMethod = PaymentMethod.offline
    
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
         paymentMethod: PaymentMethod = .offline
    ) {
        self.merchant = merchant
        self.category = category
        self.location = location
        self.amount = amount
        self.date = date
        self.card = card
        self.receiptData = receiptData
        self.billingAmount = billingAmount ?? amount
        
        // 赋值
        self.paymentMethod = paymentMethod
        
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
