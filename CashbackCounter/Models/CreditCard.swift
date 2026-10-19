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

// 两种模式下副币消费都算境外 (走外币费率和外币上限)，区别只在哪些消费入账副币、外币上限按哪个币种计价。
// case 名是历史遗留 (早期港式卡把副币并入本币轨道)，已持久化进 SwiftData / CloudKit，不能改名。
enum DualCurrencyMode: String, Codable, CaseIterable {
    // 港式双币 (如 HKD+CNY)：仅副币种地区消费入账副币；外币上限按主币计价，副币金额 1:1 计入 foreignBaseCap
    case secondaryAsLocal
    // 陆式双币 (如 CNY+USD)：所有境外消费入账副币种，foreignBaseCap 按副币种计价
    case secondaryAsForeign

    var displayName: String {
        switch self {
        case .secondaryAsLocal:
            return String.loc("外币上限按主币计 (1:1)")
        case .secondaryAsForeign:
            return String.loc("外币上限按副币计")
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
            return String.loc("返现")
        case .points:
            return String.loc("积分")
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

    // 卡包内的用户自定义顺序（长按拖动排序），越小越靠前
    var sortIndex: Int = 0
    
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

    // 👇 银行同步：这张卡关联了哪些 Plaid 账户。同样 .nullify —— 删卡不该删掉绑定记录。
    //
    // ⚠️ 这个 inverse **不是可选的装饰**：CloudKit 要求每一个关系都必须有 inverse，
    // 少了它整个 schema 会在 ModelContainer 初始化时抛
    // "CloudKit integration requires that all relationships have an inverse"，
    // 而 SharedModelContainer 的兜底逻辑会因此**删掉本地数据库**。
    // 也就是说：漏写 inverse 的后果是用户的卡包和账单全部消失。
    @Relationship(deleteRule: .nullify, inverse: \LinkedBankAccount.card)
    var linkedBankAccounts: [LinkedBankAccount]?


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

    /// 该消费地点走本币轨道还是外币轨道 (决定基础费率与基础上限)。
    /// 只看是不是发卡地：双币卡的副币消费 (如港卡在内地刷的 CNY) 同样是境外消费，
    /// 入账币种不同不改变它拿外币费率、占外币上限
    func rewardTrack(for location: Region) -> RewardTrack {
        location == issueRegion ? .local : .foreign
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
    // MARK: - 封顶计算（对外接口；实现见文末的「奖励引擎」扩展）

    /// 这一笔（含上限）的返现金额。把它放进所属结算周期、按时间顺序和其它交易一起模拟后得到。
    ///
    /// - transactionToExclude: 编辑中的那一笔，模拟时用候选值替换它
    /// - sortKey: 候选在同一天内的顺序键（新建时传预生成的 dedupeID，和保存后重算的顺序一致）；
    ///   不传时排在同一天最后，即历史交易先吃额度
    func calculateCappedCashback(amount: Double, category: Category, location: Region, date: Date,
                                 paymentMethod: PaymentMethod,
                                 transactionToExclude: Transaction? = nil,
                                 sortKey: String? = nil) -> Double {
        simulateReward(amount: amount, category: category, location: location, date: date,
                       paymentMethod: paymentMethod,
                       transactionToExclude: transactionToExclude, sortKey: sortKey).capped
    }

    /// 积分卡版本：返回积分数和按 pointValueInCardCurrency 折算的价值。
    /// 积分数不依赖估值；估值拿不到（≤ 0）时价值记 0，积分照常算。
    func calculateCappedPoints(
        amount: Double,
        category: Category,
        location: Region,
        date: Date,
        paymentMethod: PaymentMethod,
        pointValueInCardCurrency: Double,
        transactionToExclude: Transaction? = nil,
        sortKey: String? = nil
    ) -> (points: Int, value: Double) {
        let result = simulateReward(amount: amount, category: category, location: location, date: date,
                                    paymentMethod: paymentMethod,
                                    transactionToExclude: transactionToExclude, sortKey: sortKey)
        let reward = Self.pointsReward(fromCappedTotal: result.capped,
                                       pointValueInCardCurrency: pointValueInCardCurrency)
        return (points: reward.points, value: reward.value)
    }

    // MARK: - 排序

    /// 新卡插入时分配的排序号：当前最大 sortIndex + 1，保证排在末尾
    static func nextSortIndex(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<CreditCard>(
            sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let maxIndex = (try? context.fetch(descriptor))?.first?.sortIndex ?? -1
        return maxIndex + 1
    }

}

// MARK: - 记账时的公共计算（手动记账 / 快捷指令 / Plaid 同步共用）

extension CreditCard {

    /// 一点积分折算成**发卡币种**的价值。
    ///
    /// 积分计划的估值币种和卡的发卡地可以不同（比如 Amex HK 的积分按 HKD 估值，
    /// 但卡是美国发的），这时要按汇率换算一次，否则算出来的返现价值差一个汇率倍数。
    /// v1 近似：副币种入账的交易也按发卡币种估值。
    func pointValueInCardCurrency() async -> Double {
        guard let pointProgram else { return 0 }

        let pointRegion = pointProgram.valueCurrencyCode
        if pointRegion == issueRegion {
            return pointProgram.pointValue
        }

        let rates = await CurrencyService.getRates(base: pointRegion.currencyCode)
        if let rate = rates[issueRegion.currencyCode], rate > 0 {
            return pointProgram.pointValue * rate
        }
        // 拿不到汇率时退回未换算的值：偏差好过算出 0
        return pointProgram.pointValue
    }

    /// 这一笔（含上限）的奖励：返现卡给返现金额，积分卡给积分数和折算价值。amount 是入账金额
    func cappedReward(
        amount: Double,
        category: Category,
        location: Region,
        date: Date,
        paymentMethod: PaymentMethod,
        transactionToExclude: Transaction? = nil
    ) async -> (value: Double, points: Int) {
        guard rewardType == .points else {
            let cashback = calculateCappedCashback(
                amount: amount, category: category, location: location, date: date,
                paymentMethod: paymentMethod, transactionToExclude: transactionToExclude
            )
            return (cashback, 0)
        }
        let result = calculateCappedPoints(
            amount: amount, category: category, location: location, date: date,
            paymentMethod: paymentMethod, pointValueInCardCurrency: await pointValueInCardCurrency(),
            transactionToExclude: transactionToExclude
        )
        return (result.value, result.points)
    }

    /// 设置页「默认记账卡片」的存储 key，值是「银行名|尾号」
    static let defaultCardDefaultsKey = "defaultCardID"

    /// 设置里选的默认记账卡；没设、或那张卡已经删了时返回 nil
    static func defaultCard(in cards: [CreditCard]) -> CreditCard? {
        let parts = (UserDefaults.standard.string(forKey: defaultCardDefaultsKey) ?? "").split(separator: "|")
        guard parts.count == 2 else { return nil }
        return cards.first { $0.bankName == String(parts[0]) && $0.endNum == String(parts[1]) }
    }
}


// MARK: - 奖励引擎（手动记账 / 快捷指令 / Plaid 同步 / 周期重算共用）
//
// 三条规则：
//   1. 上限按**时间顺序**消耗：同一结算周期内，早的交易先吃额度。
//   2. 每一笔的封顶值是增量：min(已用 + 本笔理论, 上限) - min(已用, 上限)。
//      正数时等价于 min(本笔理论, 剩余额度)；负数（退款）时只在额度真的回落到上限以下时才扣回 ——
//      之前的 min(本笔理论, 剩余) 会把封顶后的退款全额扣回，周期总返现凭空少一截。
//   3. 存进 Transaction 的奖励是快照，周期内任何一笔增删改、卡规则变化后都要重算整个周期
//      （见 recalculateRewards）。否则删掉一笔，后面那笔本该拿回来的额度永远拿不回来。

extension CreditCard {

    /// 结算周期键：按月时是 (年, 月)，按年时是 (年, 0)
    struct PeriodKey: Hashable {
        let year: Int
        let month: Int
    }

    func periodKey(for date: Date) -> PeriodKey {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        return PeriodKey(year: year, month: capPeriod == .monthly ? calendar.component(.month, from: date) : 0)
    }

    /// 三个维度各自的理论累计用量（未封顶）。单位：返现卡是金额、积分卡是积分
    struct RewardUsage {
        var base: [RewardTrack: Double] = [:]
        var category: [Category: Double] = [:]
        var payment: [PaymentMethod: Double] = [:]
    }

    struct RewardResult {
        /// 不看上限的理论值
        let potential: Double
        /// 封顶后的实际值
        let capped: Double
        var isCapped: Bool { capped < potential - 0.000001 }
    }

    /// 增量封顶。cap <= 0 表示无上限。
    static func cappedIncrement(potential: Double, used: Double, cap: Double) -> Double {
        guard cap > 0 else { return potential }
        return min(used + potential, cap) - min(used, cap)
    }

    /// 在给定累计用量上算这一笔，并把它的理论值累加进用量（调用方按时间顺序逐笔喂）
    func applyReward(amount: Double, category: Category, location: Region, paymentMethod: PaymentMethod,
                     usage: inout RewardUsage) -> RewardResult {
        let track = rewardTrack(for: location)
        let potentialBase = amount * baseRate(forLocation: location)
        let potentialCategory = amount * (specialRates[category] ?? 0)
        let potentialPayment = amount * (paymentMethodRates[paymentMethod] ?? 0)

        let baseCap = (track == .foreign) ? foreignBaseCap : localBaseCap
        let finalBase = Self.cappedIncrement(potential: potentialBase, used: usage.base[track] ?? 0, cap: baseCap)
        let finalCategory = Self.cappedIncrement(potential: potentialCategory, used: usage.category[category] ?? 0,
                                                 cap: categoryCaps[category] ?? 0)
        let finalPayment = Self.cappedIncrement(potential: potentialPayment, used: usage.payment[paymentMethod] ?? 0,
                                                cap: paymentCaps[paymentMethod] ?? 0)

        usage.base[track, default: 0] += potentialBase
        usage.category[category, default: 0] += potentialCategory
        usage.payment[paymentMethod, default: 0] += potentialPayment

        return RewardResult(potential: potentialBase + potentialCategory + potentialPayment,
                            capped: finalBase + finalCategory + finalPayment)
    }

    /// 积分卡：封顶后的"积分总量"取整（正数向下、负数向零，退款扣回的积分也是整数），再按估值折算
    static func pointsReward(fromCappedTotal total: Double, pointValueInCardCurrency: Double) -> (points: Int, value: Double) {
        let points = Int(total.rounded(.towardZero))
        let value = pointValueInCardCurrency > 0 ? Double(points) * pointValueInCardCurrency : 0
        return (points, value)
    }

    /// 周期内交易的稳定顺序：先按日期，同一天按 dedupeID（随机但固定）。
    /// 顺序决定同一天里谁先吃额度，必须可复现，否则每次重算都会把额度分给不同的交易。
    static func rewardOrder(_ a: Transaction, _ b: Transaction) -> Bool {
        if a.date != b.date { return a.date < b.date }
        return a.dedupeID < b.dedupeID
    }

    /// 把一笔候选交易放进它所属的周期、按时间顺序模拟后得到的奖励（含上限）。
    /// 记账预览和保存前的初值都走这里；保存后再由 recalculateRewards 统一回写。
    func simulateReward(amount: Double, category: Category, location: Region, date: Date,
                        paymentMethod: PaymentMethod,
                        transactionToExclude: Transaction? = nil,
                        sortKey: String? = nil) -> RewardResult {
        let key = periodKey(for: date)
        let others = (transactions ?? []).filter {
            !$0.isDeleted && $0 != transactionToExclude && periodKey(for: $0.date) == key
        }
        // 没给顺序键就排在同一天最后：历史交易先吃额度
        let candidateKey = sortKey ?? transactionToExclude?.dedupeID ?? "\u{10FFFF}"

        // 候选和已有交易一起排序。(date, key) 相同的极端情况下候选在后
        let sortedOthers = others.sorted(by: Self.rewardOrder)
        var usage = RewardUsage()
        for t in sortedOthers {
            let candidateFirst = date < t.date || (date == t.date && candidateKey < t.dedupeID)
            if candidateFirst { break }
            _ = applyReward(amount: t.billingAmount, category: t.category, location: t.location,
                            paymentMethod: t.paymentMethod, usage: &usage)
        }
        return applyReward(amount: amount, category: category, location: location,
                           paymentMethod: paymentMethod, usage: &usage)
    }

    /// 按时间顺序重算某个结算周期内所有交易的奖励并回写 cashbackamount / pointsEarned。
    /// 返回被改动的笔数。积分卡要传入「一点积分值多少发卡币种」（见 pointValueInCardCurrency()）。
    @discardableResult
    func recalculateRewards(inPeriodOf date: Date, pointValueInCardCurrency: Double) -> Int {
        recalculateRewards(periodKey: periodKey(for: date), pointValueInCardCurrency: pointValueInCardCurrency)
    }

    @discardableResult
    func recalculateRewards(periodKey key: PeriodKey, pointValueInCardCurrency: Double) -> Int {
        let rows = (transactions ?? [])
            .filter { !$0.isDeleted && periodKey(for: $0.date) == key }
            .sorted(by: Self.rewardOrder)
        var usage = RewardUsage()
        var changed = 0
        for t in rows {
            let result = applyReward(amount: t.billingAmount, category: t.category, location: t.location,
                                     paymentMethod: t.paymentMethod, usage: &usage)
            let cashback: Double
            let points: Int
            if rewardType == .points {
                let reward = Self.pointsReward(fromCappedTotal: result.capped,
                                               pointValueInCardCurrency: pointValueInCardCurrency)
                cashback = reward.value
                points = reward.points
            } else {
                cashback = result.capped
                points = 0
            }
            if abs(t.cashbackamount - cashback) > 0.000001 || t.pointsEarned != points {
                t.cashbackamount = cashback
                t.pointsEarned = points
                changed += 1
            }
        }
        return changed
    }

    /// 重算这张卡**所有**周期（卡的费率 / 上限 / 周期改了之后用）
    @discardableResult
    func recalculateAllRewards(pointValueInCardCurrency: Double) -> Int {
        let keys = Set((transactions ?? []).filter { !$0.isDeleted }.map { periodKey(for: $0.date) })
        return keys.reduce(0) { $0 + recalculateRewards(periodKey: $1, pointValueInCardCurrency: pointValueInCardCurrency) }
    }

    /// 异步版本：积分卡会先解析一次估值（可能查汇率）
    @discardableResult
    func recalculateRewards(inPeriodOf date: Date) async -> Int {
        let pointValue = rewardType == .points ? await pointValueInCardCurrency() : 0
        return recalculateRewards(inPeriodOf: date, pointValueInCardCurrency: pointValue)
    }

    @discardableResult
    func recalculateAllRewards() async -> Int {
        let pointValue = rewardType == .points ? await pointValueInCardCurrency() : 0
        return recalculateAllRewards(pointValueInCardCurrency: pointValue)
    }
}

extension Transaction {
    /// 删除一笔交易并重算同卡同周期其余交易的奖励：它吃掉的额度要回到后面那些交易身上
    @MainActor
    static func deleteRecalculating(_ transaction: Transaction, in context: ModelContext) async {
        let card = transaction.card
        let date = transaction.date
        context.delete(transaction)
        try? context.save()
        if let card {
            await card.recalculateRewards(inPeriodOf: date)
            try? context.save()
        }
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
