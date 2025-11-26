//
//  CashbackService.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import Foundation

struct CashbackService {
    
    static func calculateCashback(for transaction: Transaction) -> Double {
            // 这里的 cashbackamount 是我们在 AddTransactionView 保存时
            // 调用 card.calculateCappedCashback 算出来的结果，已经包含上限逻辑
            return transaction.cashbackamount
        }
        
        // 👇 2. 修改或废弃：旧的计算方法
        // 这个方法之前用于预览，现在 AddTransactionView 已经直接调用 Card 的方法了。
        // 为了防止其他地方误用，我们可以把它更新为调用 Card 的新逻辑，或者直接删掉。
        // 这里演示更新版（需要补上 Date 参数）：
        static func calculateCashback(billingAmount: Double, category: Category, location: Region, card: CreditCard, date: Date = Date()) -> Double {
            return card.calculateCappedCashback(amount: billingAmount, category: category, location: location, date: date)
        }
    
    // 获取卡名
    static func getCardName(for transaction: Transaction) -> String {
        guard let card = transaction.card else { return "已删除卡片" }
        return "\(card.bankName) \(card.type)"
    }
    // 获取卡号
    static func getCardNum(for transaction: Transaction) -> String {
        guard let card = transaction.card else { return "已删除卡片" }
        return "\(card.endNum)"
    }
    // 获取货币符号
    static func getCurrency(for transaction: Transaction) -> String {
        return transaction.location.currencySymbol
    }
    
    // 获取费率
    static func getRate(for transaction: Transaction) -> Double {
        guard let card = transaction.card else { return 0.0 }
        return card.getRate(for: transaction.category, location: transaction.location)
    }
    
}

// Convert string to date
extension String {
    func toDate() -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd" // 必须符合这个格式
        return formatter.date(from: self) ?? Date() // 如果格式错了就返回今天
    }
}
