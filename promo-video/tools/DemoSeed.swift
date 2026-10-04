//
//  DemoSeed.swift
//  CashbackCounter
//
//  宣传视频 / 截图用的演示数据。仅 DEBUG + 模拟器 + 启动参数 `-DemoSeed` 时生效：
//  清空模拟器本地库（模拟器上 CloudKit 本来就是关的），再灌一套美卡场景的数据。
//

#if DEBUG && targetEnvironment(simulator)

import SwiftData
import UIKit

@MainActor
enum DemoSeed {

    static func runIfRequested(in container: ModelContainer) {
        guard ProcessInfo.processInfo.arguments.contains("-DemoSeed") else { return }
        let context = container.mainContext

        try? context.delete(model: Income.self)
        try? context.delete(model: Transaction.self)
        try? context.delete(model: LinkedBankAccount.self)
        try? context.delete(model: PointAdjustment.self)
        try? context.delete(model: CreditCard.self)
        try? context.delete(model: Point.self)
        try? context.save()

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "hasSeenOnboarding")
        defaults.set("USD", forKey: "mainCurrencyCode")
        defaults.set(0, forKey: "selectedTab")

        guard let url = Bundle.main.url(forResource: "CardTemplates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let templates = try? JSONDecoder().decode([CardTemplate].self, from: data)
        else { return }

        // ── 积分计划（估值参考美卡指南）──
        let ur = Point(bankName: "Chase", pointName: "UR", pointValue: 0.02, valueCurrencyCode: .us)
        let mr = Point(bankName: "AMEX US", pointName: "MR", pointValue: 0.02, valueCurrencyCode: .us)
        let c1 = Point(bankName: "Capital One", pointName: "Miles", pointValue: 0.0185, valueCurrencyCode: .us)
        [ur, mr, c1].forEach(context.insert)
        let pointMap: [String: Point] = Dictionary(uniqueKeysWithValues: [ur, mr, c1].map {
            (CardTemplate.pointTemplateKey(bankName: $0.bankName, pointName: $0.pointName,
                                           currencyCode: $0.valueCurrencyCode), $0)
        })

        func makeCard(_ bank: String, _ type: String, endNum: String, sort: Int) -> CreditCard? {
            guard let template = templates.first(where: { $0.bankName == bank && $0.type == type }) else {
                return nil
            }
            let card = CreditCard(bankName: bank, type: type, endNum: endNum, colorHexes: template.colors,
                                  defaultRate: 0, specialRates: [:], issueRegion: template.region)
            template.applyRules(to: card, pointMap: pointMap)
            if let name = template.pictureURL, let image = UIImage(named: name) {
                card.cardImageData = image.pngData()
            }
            card.sortIndex = sort
            card.repaymentDay = [5, 12, 18, 22, 26, 28][sort % 6]
            context.insert(card)
            return card
        }

        guard let csr = makeCard("Chase", "Sapphire Reserve", endNum: "4417", sort: 0),
              let gold = makeCard("AMEX US", "Gold", endNum: "1008", sort: 1),
              let apple = makeCard("Apple", "Card", endNum: "6688", sort: 2),
              let flex = makeCard("Chase", "Freedom Flex", endNum: "2290", sort: 3),
              let ventureX = makeCard("Capital One", "Venture X", endNum: "7731", sort: 4),
              let plat = makeCard("AMEX US", "Platinum", endNum: "3005", sort: 5)
        else { return }

        // ── 银行同步：Chase、Amex 两家已绑定 ──
        let now = Date()
        let accounts = [
            LinkedBankAccount(itemId: "demo-chase", accountId: "demo-1", institutionName: "Chase",
                              accountName: "Sapphire Reserve", mask: "4417", card: csr, syncEnabled: true),
            LinkedBankAccount(itemId: "demo-chase", accountId: "demo-2", institutionName: "Chase",
                              accountName: "Freedom Flex", mask: "2290", card: flex, syncEnabled: true),
            LinkedBankAccount(itemId: "demo-amex", accountId: "demo-3", institutionName: "American Express",
                              accountName: "Gold Card", mask: "1008", card: gold, syncEnabled: true),
            LinkedBankAccount(itemId: "demo-amex", accountId: "demo-4", institutionName: "American Express",
                              accountName: "Platinum Card", mask: "3005", card: plat, syncEnabled: true)
        ]
        for account in accounts {
            account.lastSyncedAt = now.addingTimeInterval(-120)
            account.didInitialSync = true
            context.insert(account)
        }
        let syncedCards: Set<ObjectIdentifier> = Set([csr, flex, gold, plat].map(ObjectIdentifier.init))

        // ── 交易 ──
        let calendar = Calendar.current
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        func add(_ merchant: String, _ category: Category, _ amount: Double, _ card: CreditCard,
                 _ date: Date, _ payment: PaymentMethod = .offline) {
            var cashback = 0.0
            var points = 0
            if card.rewardType == .points {
                let result = card.calculateCappedPoints(
                    amount: amount, category: category, location: .us, date: date,
                    paymentMethod: payment, pointValueInCardCurrency: card.pointProgram?.pointValue ?? 0)
                cashback = result.value
                points = result.points
            } else {
                cashback = card.calculateCappedCashback(
                    amount: amount, category: category, location: .us, date: date, paymentMethod: payment)
            }
            let source: TransactionSource = syncedCards.contains(ObjectIdentifier(card)) ? .plaid : .manual
            let transaction = Transaction(
                merchant: merchant, category: category, location: .us, amount: amount, date: date,
                card: card, billingAmount: amount, cashbackAmount: cashback, pointsEarned: points,
                paymentMethod: payment, billingCurrencyCode: "USD", source: source)
            context.insert(transaction)
        }

        // 近期：账单首页第一屏能看到的那些。
        // 第一笔是"快捷指令收到短信自动记的那一笔"，-DemoSkipLatest 时不灌，用来截记账前的画面
        if !ProcessInfo.processInfo.arguments.contains("-DemoSkipLatest") {
            add("Blue Bottle Coffee", .dining, 6.75, ventureX, at(0, 9, 12))
        }
        add("Whole Foods Market", .grocery, 86.42, gold, at(0, 8, 40))
        add("Uber", .travel, 23.18, csr, at(1, 22, 5), .online)
        add("Trader Joe's", .grocery, 54.37, gold, at(1, 18, 30))
        add("Netflix", .streaming, 15.49, flex, at(2, 3, 0), .online)
        add("Shake Shack", .dining, 28.60, csr, at(2, 13, 15))
        add("Apple Store", .digital, 1_099.00, apple, at(3, 15, 20), .applePay)
        add("Delta Air Lines", .travel, 412.30, plat, at(4, 11, 0), .online)
        add("Costco Wholesale", .grocery, 213.85, ventureX, at(5, 17, 45))
        add("Chipotle", .dining, 14.25, gold, at(6, 12, 30))
        add("Lyft", .travel, 18.90, csr, at(7, 23, 10), .online)
        add("Target", .grocery, 67.12, flex, at(8, 16, 0))
        add("Marriott Hotels", .travel, 389.00, csr, at(10, 14, 0), .online)
        add("Spotify", .streaming, 11.99, flex, at(11, 4, 0), .online)
        add("Sweetgreen", .dining, 17.45, gold, at(12, 12, 50))
        add("Best Buy", .digital, 249.99, ventureX, at(14, 19, 20))
        add("DoorDash", .dining, 42.30, gold, at(15, 20, 15), .online)
        add("Starbucks", .dining, 7.25, apple, at(17, 8, 20), .applePay)

        // 往前五个月：趋势图有起伏
        var rng = SeededRandom(seed: 41)
        let recurring: [(String, Category, ClosedRange<Double>, CreditCard, PaymentMethod)] = [
            ("Whole Foods Market", .grocery, 60...140, gold, .offline),
            ("Trader Joe's", .grocery, 35...90, gold, .offline),
            ("Uber", .travel, 14...45, csr, .online),
            ("Shake Shack", .dining, 18...40, csr, .offline),
            ("Chipotle", .dining, 11...24, gold, .offline),
            ("Costco Wholesale", .grocery, 120...320, ventureX, .offline),
            ("Netflix", .streaming, 15.49...15.49, flex, .online),
            ("Amazon", .other, 25...180, flex, .online),
            ("Starbucks", .dining, 5...9, apple, .applePay),
            ("United Airlines", .travel, 180...620, plat, .online)
        ]
        for month in 1...5 {
            for (index, item) in recurring.enumerated() {
                let repeats = item.1 == .dining || item.1 == .grocery ? 3 : 1
                for r in 0..<repeats {
                    let day = month * 30 + index * 2 + r * 9
                    let amount = (rng.next(in: item.2) * 100).rounded() / 100
                    add(item.0, item.1, amount, item.3, at(day, 12 + r * 3, index * 5), item.4)
                }
            }
        }

        try? context.save()
    }
}

/// 固定种子的伪随机数，保证每次灌出来的数据一样，截图可复现。
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

#endif
