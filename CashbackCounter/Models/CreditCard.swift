//
//  CreditCard.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import SwiftData

enum CapPeriod: Codable {
    case yearly
    case monthly
}

@Model // 👈 1. 变身数据库表
class CreditCard: Identifiable {
    // 自动生成的主键，不需要手动 id 了
    
    var bankName: String
    var type: String
    var endNum: String
    var repaymentDay: Int = 0
    var isRemindOpen: Bool = true // 默认为 true (直接开启)
    
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

    // 记录该卡是否来源于某个模板，便于模板更新时同步规则
    var templateKey: String?
    
    // 👇👇👇 1. 修改上限属性
        
    // A. 基础返现上限 (双轨制：分本币/外币)
    // 0 代表无上限
    var localBaseCap: Double
    var foreignBaseCap: Double
    
    // 返现上限结算周期：按年 / 按月
    var capPeriod: CapPeriod
        
    // B. 类别加成上限 (共用制：不分地区，只看类别)
    // Key: 消费类别, Value: 该类别在一个结算周期(capPeriod)内的总加成上限
    var categoryCaps: [Category: Double]
        
    
    // 👇 4. 建立反向关系 (可选)：这张卡关联了哪些交易？
    // 当你删卡时，关联的交易怎么办？.nullify 意思是把交易里的卡变成空，保留交易记录
    @Relationship(deleteRule: .nullify, inverse: \Transaction.card)
    var transactions: [Transaction]?
    
    init(bankName: String,
            type: String,
            endNum: String,
            colorHexes: [String],
            defaultRate: Double,
            specialRates: [Category: Double],
            issueRegion: Region,
            foreignCurrencyRate: Double? = nil,
            templateKey: String? = nil,
            // 新参数
            localBaseCap: Double = 0,
            foreignBaseCap: Double = 0,
            categoryCaps: [Category: Double] = [:], // 改为单字典
            capPeriod: CapPeriod = .yearly,
            repaymentDay: Int = 0,
            isRemindOpen: Bool = true
    ) {
        self.bankName = bankName
        self.type = type
        self.endNum = endNum
        self.colorHexes = colorHexes
        self.defaultRate = defaultRate
        self.specialRates = specialRates
        self.issueRegion = issueRegion
        self.foreignCurrencyRate = foreignCurrencyRate
        self.templateKey = templateKey

        // 赋值
        self.localBaseCap = localBaseCap
        self.foreignBaseCap = foreignBaseCap
        self.capPeriod = capPeriod
        self.categoryCaps = categoryCaps
        self.repaymentDay = repaymentDay
        self.isRemindOpen = isRemindOpen
    }
    
    func getRate(for category: Category, location: Region) -> Double {
        // 1. 获取类别带来的“额外”加成 (Category Bonus)
        // 使用 ?? 0.0 避免字典里没有该类别时发生崩溃
        let categoryBonus = specialRates[category] ?? 0.0
        
        // 2. 确定基础费率 (Base Rate)
        var baseRate = defaultRate
        
        // 如果消费地 != 发卡地，且设置了境外费率，则使用境外费率作为基础
        // (假设你的逻辑是：境外费率取代基础费率，然后再叠加类别)
        if location != issueRegion, let foreignRate = foreignCurrencyRate, foreignRate > 0 {
            baseRate = foreignRate
        }
        
        // 3. 核心修改：将基础费率与类别加成相加
        return baseRate + categoryBonus
    }
    func calculateCappedCashback(amount: Double, category: Category, location: Region, date: Date, transactionToExclude: Transaction? = nil) -> Double {
            
            let isForeign = (location != issueRegion)
            
            // --- 第一步：准备费率和当笔理论值 ---
            var baseRate = defaultRate
            if isForeign, let fr = foreignCurrencyRate, fr > 0 {
                baseRate = fr
            }
            let potentialBaseReward = amount * baseRate
            
            let bonusRate = specialRates[category] ?? 0.0
            let potentialBonusReward = amount * bonusRate
            
            // --- 第二步：准备上限阈值 ---
            let baseCapLimit = isForeign ? foreignBaseCap : localBaseCap
            let categoryCapLimit = categoryCaps[category] ?? 0.0
            
            // --- 第三步：统计历史用量 ---
            let calendar = Calendar.current
            let currentYear = calendar.component(.year, from: date)
            let currentMonth = calendar.component(.month, from: date)
            
            // 筛选同一张卡在同一结算周期内的交易（排除正在编辑的这一笔）
            let periodTransactions = (transactions ?? []).filter { t in
                let year = calendar.component(.year, from: t.date)
                guard year == currentYear else { return false }
                
                let isNotSelf = (t != transactionToExclude)
                guard isNotSelf else { return false }
                
                switch capPeriod {
                case .yearly:
                    // 同一年即可
                    return true
                case .monthly:
                    let month = calendar.component(.month, from: t.date)
                    return month == currentMonth
                }
            }
            
            // A. 计算已用基础返现 (估算值)
            var usedBase: Double = 0
            if baseCapLimit > 0 {
                usedBase = periodTransactions
                    .filter { ($0.location != self.issueRegion) == isForeign }
                    .reduce(0) { sum, t in
                        let tBaseRate = ((t.location != self.issueRegion) && (foreignCurrencyRate ?? 0) > 0) ? (foreignCurrencyRate ?? 0) : defaultRate
                        return sum + (t.billingAmount * tBaseRate)
                    }
            }
            
            // B. 计算已用加成返现 (估算值)
            var usedBonus: Double = 0
            if categoryCapLimit > 0 {
                usedBonus = periodTransactions
                    .filter { $0.category == category }
                    .reduce(0) { sum, t in
                        let tBonusRate = specialRates[t.category] ?? 0.0
                        return sum + (t.billingAmount * tBonusRate)
                    }
            }
            
            // --- 第四步：结算 (Reward Cap 逻辑) ---
            var finalBase = potentialBaseReward
            if baseCapLimit > 0 {
                let remaining = max(0, baseCapLimit - usedBase)
                finalBase = min(potentialBaseReward, remaining)
            }
            
            var finalBonus = potentialBonusReward
            if categoryCapLimit > 0 {
                let remaining = max(0, categoryCapLimit - usedBonus)
                finalBonus = min(potentialBonusReward, remaining)
            }
            
            return finalBase + finalBonus
        }
    func calculateCappedCashback(amount: Double, category: Category, location: Region, date: Date) -> Double {
            
            let isForeign = (location != issueRegion)
            
            // --- 第一步：准备费率和当笔理论值 ---
            
            // 1. 基础部分 (Base)
            var baseRate = defaultRate
            if isForeign, let fr = foreignCurrencyRate, fr > 0 {
                baseRate = fr
            }
            let potentialBaseReward = amount * baseRate
            
            // 2. 加成部分 (Bonus)
            let bonusRate = specialRates[category] ?? 0.0
            let potentialBonusReward = amount * bonusRate
            
            // --- 第二步：准备上限阈值 ---
            
            let baseCapLimit = isForeign ? foreignBaseCap : localBaseCap
            let categoryCapLimit = categoryCaps[category] ?? 0.0
            
            // --- 第三步：统计历史用量 (关键) ---
            // 我们需要计算“当前结算周期已经产生了多少理论返现”，来看看是否触发上限
            
            let calendar = Calendar.current
            let currentYear = calendar.component(.year, from: date)
            let currentMonth = calendar.component(.month, from: date)
            
            // 筛选当前结算周期内的所有交易
            let periodTransactions = (transactions ?? []).filter { t in
                let year = calendar.component(.year, from: t.date)
                guard year == currentYear else { return false }
                
                switch capPeriod {
                case .yearly:
                    // 同一年即可
                    return true
                case .monthly:
                    let month = calendar.component(.month, from: t.date)
                    return month == currentMonth
                }
            }
            
            // A. 计算已用的“基础额度”
            // 规则：只累加“同区域类型”(本币vs外币) 的交易产生的“基础返现”
            var usedBase: Double = 0
            if baseCapLimit > 0 {
                usedBase = periodTransactions
                    .filter { ($0.location != self.issueRegion) == isForeign } // 筛选同区域
                    .reduce(0) { sum, t in
                        // 估算历史交易的基础返现 (Spend * BaseRate)
                        // 注意：这里假设历史费率没变，用当前费率估算
                        let tBaseRate = ((t.location != self.issueRegion) && (foreignCurrencyRate ?? 0) > 0) ? (foreignCurrencyRate ?? 0) : defaultRate
                        return sum + (t.billingAmount * tBaseRate)
                    }
            }
            
            // B. 计算已用的“类别加成额度”
            // 规则：累加“同类别”的交易产生的“加成返现” (不管它是在哪里消费的，因为是共用池)
            var usedBonus: Double = 0
            if categoryCapLimit > 0 {
                usedBonus = periodTransactions
                    .filter { $0.category == category } // 筛选同类别
                    .reduce(0) { sum, t in
                        // 估算历史交易的加成返现
                        let tBonusRate = specialRates[t.category] ?? 0.0
                        return sum + (t.billingAmount * tBonusRate)
                    }
            }
            
            // --- 第四步：结算 ---
            
            // 1. 结算基础部分
            var finalBase = potentialBaseReward
            if baseCapLimit > 0 {
                let remaining = max(0, baseCapLimit - usedBase)
                finalBase = min(potentialBaseReward, remaining)
            }
            
            // 2. 结算加成部分
            var finalBonus = potentialBonusReward
            if categoryCapLimit > 0 {
                let remaining = max(0, categoryCapLimit - usedBonus)
                finalBonus = min(potentialBonusReward, remaining)
            }
            
            // --- 第五步：相加返回 ---
            return finalBase + finalBonus
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
