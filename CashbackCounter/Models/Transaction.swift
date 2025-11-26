import SwiftUI
import SwiftData

@Model
class Transaction: Identifiable {
    var merchant: String
    var category: Category
    var location: Region
    
    var amount: Double        // 原币金额
    var billingAmount: Double // 入账金额
    
    var date: Date
    var cashbackamount: Double
    var rate: Double
    
    var card: CreditCard?
    
    @Attribute(.externalStorage) var receiptData: Data?
    
    // 👇 修改 init 方法，增加 cashbackAmount 参数
    init(merchant: String,
         category: Category,
         location: Region,
         amount: Double,
         date: Date,
         card: CreditCard?,
         receiptData: Data? = nil,
         billingAmount: Double? = nil,
         cashbackAmount: Double? = nil // 👈 新增可选参数
    ) {
        self.merchant = merchant
        self.category = category
        self.location = location
        self.amount = amount
        self.date = date
        self.card = card
        self.receiptData = receiptData
        self.billingAmount = billingAmount ?? amount
        
        let finalBilling = billingAmount ?? amount
        
        // 1. 记录名义费率 (用于界面显示，比如 "5%")
        // 这里依然调用 getRate，得到的是 "基础+加成" 的理论总费率
        let nominalRate = card?.getRate(for: category, location: location) ?? 0
        self.rate = nominalRate
        
        // 2. 确定实际返现额 (优先使用传入的计算结果)
        if let providedCashback = cashbackAmount {
            // 如果外部传了（也就是经过了上限计算），就用外部的
            self.cashbackamount = providedCashback
        } else {
            // 兜底：如果没传，就按简单的 费率*金额 算 (兼容旧代码)
            self.cashbackamount = finalBilling * nominalRate
        }
    }
    
    var color: Color { category.color }
    var dateString: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd" // 你可以改成 "yyyy-MM-dd" 或 "MM月dd日"
            return formatter.string(from: date)
        }
}
