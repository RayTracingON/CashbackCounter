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

enum DualCurrencyMode: String, Codable, CaseIterable {
    // 港式双币 (如 HKD+CNY)：仅副币种地区消费入账副币，费率/上限并入本币轨道 (金额 1:1 计入 localBaseCap)
    case secondaryAsLocal
    // 陆式双币 (如 CNY+USD)：所有境外消费入账副币种，走外币轨道 (foreignBaseCap 即副币种独立上限)
    case secondaryAsForeign

    var displayName: String {
        switch self {
        case .secondaryAsLocal:
            return "并入本币上限 (1:1)"
        case .secondaryAsForeign:
            return "独立外币上限"
        }
    }
}

// 消费落在哪条基础费率/上限轨道上，纯计算辅助，不持久化
enum RewardTrack {
    case local
    case foreign
}

enum RewardType: String, Codable, CaseIterable {
    case cashback
    case points

    var displayName: String {
        switch self {
        case .cashback:
            return String(localized: "返现")
        case .points:
            return String(localized: "积分")
        }
    }
}

@Model // 👈 1. 变身数据库表
class CreditCard: Identifiable {
    // 自动生成的主键，不需要手动 id 了
    var bankName: String = ""
    var type: String = ""
    var endNum: String = ""
    var memo: String = "" // 👈 新增：备注
    var repaymentDay: Int = 0
    var isRemindOpen: Bool = true // 默认为 true (直接开启)
    
    // ⚠️ 2. 颜色处理：数据库存 Hex 字符串，App 用 Color
    var colorHexes: [String] = []
    @Transient // 告诉数据库不要存这个属性，这是算出来的
    var colors: [Color] {
        return colorHexes.map { Color(hex: $0) }
    }
    
    var defaultRate: Double = 0.0
    // 3. 字典处理：SwiftData 对字典支持有限，但 Category 是 Codable 的，通常可以直接存。
    // 如果这里报错，我们需要换成 JSON String。目前先尝试直接存。
    var specialRates: [Category: Double] = [:]
    var paymentMethodRates: [PaymentMethod: Double] = [:] // 针对支付方式的加成费率

    var rewardType: RewardType = RewardType.cashback
    var pointProgram: Point?

    
    var issueRegion: Region = Region.cn
    var foreignCurrencyRate: Double?

    // 双币卡：第二入账币种地区，nil = 单币卡
    var secondaryRegion: Region? = nil
    var dualCurrencyMode: DualCurrencyMode = DualCurrencyMode.secondaryAsLocal
    // 副币种入账消费的基础费率覆盖 (小数，0.01 = 1%)；nil 则用所在轨道的常规费率
    var secondaryRate: Double? = nil

    @Transient
    var isDualCurrency: Bool {
        secondaryRegion != nil && secondaryRegion != issueRegion
    }

    // 记录该卡是否来源于某个模板，便于模板更新时同步规则
    var templateKey: String?
    
    // 👇👇👇 1. 修改上限属性
        
    // A. 基础返现上限 (双轨制：分本币/外币)
    // 0 代表无上限
    var localBaseCap: Double = 0.0
    var foreignBaseCap: Double = 0.0
    
    // 返现上限结算周期：按年 / 按月
    var capPeriod: CapPeriod = CapPeriod.yearly
        
    // B. 类别加成上限 (共用制：不分地区，只看类别)
    // Key: 消费类别, Value: 该类别在一个结算周期(capPeriod)内的总加成上限
    var categoryCaps: [Category: Double] = [:]
    var paymentCaps: [PaymentMethod: Double] = [:]
        
    @Attribute(.externalStorage) var cardImageData: Data? = nil // 👈 新增：存储图片二进制数据
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
        capPeriod: CapPeriod = CapPeriod.yearly,
        repaymentDay: Int = 0,
        memo: String = "", // 👈 新增参数
        isRemindOpen: Bool = true,
        paymentMethodRates: [PaymentMethod: Double] = [:],
        paymentCaps: [PaymentMethod: Double] = [:],
        rewardType: RewardType = RewardType.cashback,
        pointProgram: Point? = nil,
        cardImageData: Data? = nil, // 👈 新增参数
        secondaryRegion: Region? = nil,
        dualCurrencyMode: DualCurrencyMode = .secondaryAsLocal,
        secondaryRate: Double? = nil
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
        self.memo = memo // 👈 赋值
        self.isRemindOpen = isRemindOpen
        self.paymentMethodRates = paymentMethodRates
        self.paymentCaps = paymentCaps
        self.rewardType = rewardType
        self.pointProgram = pointProgram
        self.cardImageData = cardImageData // 👈 赋值
        self.secondaryRegion = secondaryRegion
        self.dualCurrencyMode = dualCurrencyMode
        self.secondaryRate = secondaryRate
    }

    // MARK: - 双币卡解析 (所有费率/上限/入账币种判定的统一入口)

    /// 该消费地点对应的入账币种地区
    func billingRegion(for location: Region) -> Region {
        guard let secondary = secondaryRegion, secondary != issueRegion else {
            return issueRegion
        }
        switch dualCurrencyMode {
        case .secondaryAsLocal:
            return location == secondary ? secondary : issueRegion
        case .secondaryAsForeign:
            return location == issueRegion ? issueRegion : secondary
        }
    }

    /// 该消费地点走本币轨道还是外币轨道 (决定基础费率与基础上限)
    func rewardTrack(for location: Region) -> RewardTrack {
        guard let secondary = secondaryRegion, secondary != issueRegion else {
            // 单币卡：与旧逻辑 (location != issueRegion 即外币) 完全一致
            return location == issueRegion ? .local : .foreign
        }
        switch dualCurrencyMode {
        case .secondaryAsLocal:
            // 港式：副币地区消费并入本币轨道，上限按 1:1 合并
            return (location == issueRegion || location == secondary) ? .local : .foreign
        case .secondaryAsForeign:
            return location == issueRegion ? .local : .foreign
        }
    }

    /// 该消费地点适用的基础费率 (含 secondaryRate 覆盖)
    func baseRate(forLocation location: Region) -> Double {
        if isDualCurrency,
           billingRegion(for: location) == secondaryRegion,
           let sr = secondaryRate, sr > 0 {
            return sr
        }
        switch rewardTrack(for: location) {
        case .local:
            return defaultRate
        case .foreign:
            if let fr = foreignCurrencyRate, fr > 0 {
                return fr
            }
            return defaultRate
        }
    }
    
    func getRate(for category: Category, location: Region, payment: PaymentMethod) -> Double {
        // 1. 获取类别带来的“额外”加成 (Category Bonus)
        // 使用 ?? 0.0 避免字典里没有该类别时发生崩溃
        let categoryBonus = specialRates[category] ?? 0.0
        let paymentBonus = paymentMethodRates[payment] ?? 0.0

        // 2. 基础费率按轨道解析 (单币卡行为不变，双币卡含 secondaryRate 覆盖)
        let currentBaseRate = baseRate(forLocation: location)

        // 3. 核心修改：将基础费率与类别加成相加
        return currentBaseRate + categoryBonus + paymentBonus
    }
    func calculateCappedCashback(amount: Double, category: Category, location: Region, date: Date, paymentMethod: PaymentMethod, transactionToExclude: Transaction? = nil) -> Double {
            
        let track = rewardTrack(for: location)

        // --- 第一步：准备费率和当笔理论值 ---
        let currentBaseRate = baseRate(forLocation: location)
        let potentialBaseReward = amount * currentBaseRate

        let categoryBonusRate = specialRates[category] ?? 0.0
        let paymentBonusRate  = paymentMethodRates[paymentMethod] ?? 0.0 // 确保 CreditCard 有这个字典

        let potentialCategoryReward = amount * categoryBonusRate
        let potentialPaymentReward  = amount * paymentBonusRate

        // --- 第二步：准备上限阈值 ---
        let baseCapLimit = (track == .foreign) ? foreignBaseCap : localBaseCap
        let categoryCapLimit = categoryCaps[category] ?? 0.0
        let paymentCapLimit = paymentCaps[paymentMethod] ?? 0.0 // ⚠️ 确保 CreditCard 类里定义了 paymentCaps
            
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
                return true
            case .monthly:
                let month = calendar.component(.month, from: t.date)
                return month == currentMonth
            }
        }
            
        // A. 计算已用基础返现 (估算值)
        // 注意：这里假设历史费率未变。港式双币卡的副币账单金额直接累加，即按 1:1 计入本币上限
        var usedBase: Double = 0
        if baseCapLimit > 0 {
            usedBase = periodTransactions
                .filter { rewardTrack(for: $0.location) == track }
                .reduce(0) { $0 + ($1.billingAmount * baseRate(forLocation: $1.location)) }
        }
            
        // B. 计算已用类别加成返现 (Category Used)
        var usedCategoryBonus: Double = 0 // 💡 改名：明确这是类别用的
        if categoryCapLimit > 0 {
            usedCategoryBonus = periodTransactions
                .filter { $0.category == category }
                .reduce(0) { sum, t in
                    let tBonusRate = specialRates[t.category] ?? 0.0
                    return sum + (t.billingAmount * tBonusRate)
                }
        }
        
        // C. 计算已用支付方式加成返现 (Payment Method Used)
        var usedPaymentBonus: Double = 0 // 💡 改名：明确这是支付方式用的
        if paymentCapLimit > 0 {
            usedPaymentBonus = periodTransactions
                .filter { $0.paymentMethod == paymentMethod }
                .reduce(0) { sum, t in
                    let tBonusRate = paymentMethodRates[t.paymentMethod] ?? 0.0
                    return sum + (t.billingAmount * tBonusRate)
                }
        }
        
        // --- 第四步：结算 (Reward Cap 逻辑) ---
        
        // 1. 结算基础
        var finalBase = potentialBaseReward
        if baseCapLimit > 0 {
            let remaining = max(0, baseCapLimit - usedBase)
            finalBase = min(potentialBaseReward, remaining)
        }
            
        // 2. 结算类别加成
        var finalCategoryBonus = potentialCategoryReward
        if categoryCapLimit > 0 {
            // ✅ 修正：这里使用 usedCategoryBonus
            let remaining = max(0, categoryCapLimit - usedCategoryBonus)
            finalCategoryBonus = min(potentialCategoryReward, remaining)
        }
        
        // 3. 结算支付方式加成
        var finalPaymentBonus = potentialPaymentReward
        if paymentCapLimit > 0 {
            // ✅ 修正：这里必须减去 usedPaymentBonus，而不是 usedCategoryBonus
            let remaining = max(0, paymentCapLimit - usedPaymentBonus)
            finalPaymentBonus = min(potentialPaymentReward, remaining)
        }
        
        // --- 第五步：汇总返回 ---
        return finalBase + finalCategoryBonus + finalPaymentBonus
    }
    
    func calculateCappedPoints(
        amount: Double,
        category: Category,
        location: Region,
        date: Date,
        paymentMethod: PaymentMethod,
        pointValueInCardCurrency: Double,
        transactionToExclude: Transaction? = nil
    ) -> (points: Int, value: Double) {
        guard pointValueInCardCurrency > 0 else {
            return (points: 0, value: 0)
        }
        
        let track = rewardTrack(for: location)

        let currentBaseRate = baseRate(forLocation: location)

        let potentialBasePoints = (amount * currentBaseRate)
        let categoryBonusRate = specialRates[category] ?? 0.0
        let paymentBonusRate = paymentMethodRates[paymentMethod] ?? 0.0

        let potentialCategoryPoints = (amount * categoryBonusRate)
        let potentialPaymentPoints = (amount * paymentBonusRate)

        let baseCapLimit = (track == .foreign) ? foreignBaseCap : localBaseCap
        let categoryCapLimit = categoryCaps[category] ?? 0.0
        let paymentCapLimit = paymentCaps[paymentMethod] ?? 0.0
        
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: date)
        let currentMonth = calendar.component(.month, from: date)
        
        let periodTransactions = (transactions ?? []).filter { t in
            let year = calendar.component(.year, from: t.date)
            guard year == currentYear else { return false }
            
            let isNotSelf = (t != transactionToExclude)
            guard isNotSelf else { return false }
            
            switch capPeriod {
            case .yearly:
                return true
            case .monthly:
                let month = calendar.component(.month, from: t.date)
                return month == currentMonth
            }
        }
        
        var usedBasePoints: Double = 0
        if baseCapLimit > 0 {
            usedBasePoints = periodTransactions
                .filter { rewardTrack(for: $0.location) == track }
                .reduce(0) { $0 + ($1.billingAmount * baseRate(forLocation: $1.location)) }
        }
        
        var usedCategoryPoints: Double = 0
        if categoryCapLimit > 0 {
            usedCategoryPoints = periodTransactions
                .filter { $0.category == category }
                .reduce(0) { sum, t in
                    let tBonusRate = specialRates[t.category] ?? 0.0
                    return sum + (t.billingAmount * tBonusRate)
                }
        }
        
        var usedPaymentPoints: Double = 0
        if paymentCapLimit > 0 {
            usedPaymentPoints = periodTransactions
                .filter { $0.paymentMethod == paymentMethod }
                .reduce(0) { sum, t in
                    let tBonusRate = paymentMethodRates[t.paymentMethod] ?? 0.0
                    return sum + (t.billingAmount * tBonusRate)
                }
        }
        
        var finalBasePoints = potentialBasePoints
        if baseCapLimit > 0 {
            let remaining = max(0, baseCapLimit - usedBasePoints)
            finalBasePoints = min(potentialBasePoints, remaining)
        }
        
        var finalCategoryPoints = potentialCategoryPoints
        if categoryCapLimit > 0 {
            let remaining = max(0, categoryCapLimit - usedCategoryPoints)
            finalCategoryPoints = min(potentialCategoryPoints, remaining)
        }
        
        var finalPaymentPoints = potentialPaymentPoints
        if paymentCapLimit > 0 {
            let remaining = max(0, paymentCapLimit - usedPaymentPoints)
            finalPaymentPoints = min(potentialPaymentPoints, remaining)
        }
        
        let totalPoints = finalBasePoints + finalCategoryPoints + finalPaymentPoints
        let pointsEarned = max(0, Int(floor(totalPoints)))
        let value = Double(pointsEarned) * pointValueInCardCurrency
        
        return (points: pointsEarned, value: value)
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
