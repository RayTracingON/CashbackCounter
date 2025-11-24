//
//  Transaction.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import SwiftData // 👈 1. 引入新框架
@Model
class Transaction: Identifiable {
    var merchant: String
    // Enum 需要遵守 Codable 才能存进 SwiftData (之前我们加过 Codable 了)
    var category: Category
    var location: Region
    var amount: Double
    var date: Date
    var cashbackamount: Double
    // 👇 核心修改：不再存 UUID，直接存 CreditCard 对象！
    // 这是一个 Optional，因为万一卡片被删了，这个字段就会变成 nil
    var card: CreditCard?
    
    @Attribute(.externalStorage) var receiptData: Data?
    
    init(merchant: String, category: Category, location: Region, amount: Double, date: Date, card: CreditCard?, receiptData: Data? = nil) {
        self.merchant = merchant
        self.category = category
        self.location = location
        self.amount = amount
        self.date = date
        self.card = card // 直接把对象存进去
        self.receiptData = receiptData // 赋值
        self.cashbackamount = CashbackService.calculateCashback(amount: amount, category: category, location: location, card: card!)
    }
    
    var color: Color { category.color }
    var dateString: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd" // 你可以改成 "yyyy-MM-dd" 或 "MM月dd日"
            return formatter.string(from: date)
        }
}

enum Region: String, CaseIterable, Codable {
    case cn = "中国大陆"
    case hk = "中国香港"
    case us = "美国"
    case other = "其他地区"
    
    var icon: String {
        switch self {
        case .cn: return "🇨🇳" // 直接用 Emoji，简单明了
        case .hk: return "🇭🇰"
        case .us: return "🇺🇸"
        case .other: return "🌍"
        }
    }
    var currencySymbol: String {
        switch self {
        case .cn: return "¥"
        case .hk: return "HK$"
        case .us: return "$"
        case .other: return "€" // 或者用通用符号 ¤
        }
    }
}
