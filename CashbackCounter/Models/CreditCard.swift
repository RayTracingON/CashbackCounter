//
//  CreditCard.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import SwiftData

@Model // 👈 1. 变身数据库表
class CreditCard: Identifiable {
    // 自动生成的主键，不需要手动 id 了
    
    var bankName: String
    var type: String
    var endNum: String
    
    // ⚠️ 2. 颜色处理：数据库存 Hex 字符串，App 用 Color
    var colorHexes: [String]
    @Transient // 告诉数据库不要存这个属性，这是算出来的
    var colors: [Color] {
        return colorHexes.map { Color(hex: $0) }
    }
    
    var defaultRate: Double
    // 3. 字典处理：SwiftData 对字典支持有限，但 Category 是 Codable 的，通常可以直接存。
    // 如果这里报错，我们需要换成 JSON String。目前先尝试直接存。
    var specialRates: [Category: Double]
    
    var issueRegion: Region
    var foreignCurrencyRate: Double?
    
    // 👇 4. 建立反向关系 (可选)：这张卡关联了哪些交易？
    // 当你删卡时，关联的交易怎么办？.nullify 意思是把交易里的卡变成空，保留交易记录
    @Relationship(deleteRule: .nullify, inverse: \Transaction.card)
    var transactions: [Transaction]?
    
    init(bankName: String, type: String, endNum: String, colorHexes: [String], defaultRate: Double, specialRates: [Category: Double], issueRegion: Region, foreignCurrencyRate: Double? = nil) {
        self.bankName = bankName
        self.type = type
        self.endNum = endNum
        self.colorHexes = colorHexes
        self.defaultRate = defaultRate
        self.specialRates = specialRates
        self.issueRegion = issueRegion
        self.foreignCurrencyRate = foreignCurrencyRate
    }
    
    // ... 之前的 getRate 方法保持不变 (记得要把 specialRates 改一下调用方式如果变了) ...
    func getRate(for category: Category, location: Region) -> Double {
        let categoryRate = specialRates[category] ?? defaultRate
        if location != issueRegion, let foreignRate = foreignCurrencyRate {
            return max(categoryRate, foreignRate)
        }
        return categoryRate
    }
}

// 👇 必须加这个 Extension 才能让颜色和字符串互转
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}


extension Color {
    // 把 Color 转成 Hex 字符串 (例如 "FF0000")
    func toHex() -> String? {
        let uic = UIColor(self)
        guard let components = uic.cgColor.components, components.count >= 3 else {
            return nil
        }
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        var a = Float(1.0)
        
        if components.count >= 4 {
            a = Float(components[3])
        }
        
        if a != Float(1.0) {
            return String(format: "%02lX%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255), lroundf(a * 255))
        } else {
            return String(format: "%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
        }
    }
}
