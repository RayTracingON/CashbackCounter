//
//  PreviewSupport.swift
//  CashbackCounter
//
//  所有 `#Preview` 共用的假数据源。整个文件包在 `#if DEBUG` 里，不进 Release 包。
//
//  为什么要集中一份，而不是每个 preview 各自造对象：
//  1. 这个 App 里大部分视图靠 `@Query` 读 SwiftData，不挂容器就是白屏 —— 而挂真容器
//     会连上本地库和 iCloud，预览会污染真实数据。所以统一走一个内存容器。
//  2. 卡片 → 交易 → 收入 是有关系的：交易没关联卡片就算不出返现和积分，
//     卡片没有交易就看不到上限进度条。散着造很容易得到一堆"半成品"数据，
//     预览看起来是空的，误以为视图坏了。
//

#if DEBUG

import SwiftData
import SwiftUI
import UIKit

@MainActor
enum PreviewData {

    // MARK: - 容器

    /// 预览用内存数据库：不落盘、不连 CloudKit，已灌好样例数据。
    ///
    /// 带 `@Query` 或 `@Environment(\.modelContext)` 的视图都要挂它（用 `previewEnvironment()`）。
    static var container: ModelContainer { seeded.container }

    /// 空数据库：专门用来看各页的空状态（"暂无卡片"/"暂无积分计划"这类分支）。
    static let emptyContainer: ModelContainer = makeContainer()

    // MARK: - 卡片

    static var cards: [CreditCard] { seeded.cards }

    /// 返现卡：人民币、月度上限、餐饮加成。用来看进度条和封顶逻辑。
    static var cashbackCard: CreditCard { seeded.cards[0] }

    /// 积分卡：港币、绑了积分计划。用来看积分相关展示。
    static var pointsCard: CreditCard { seeded.cards[1] }

    /// 港式双币卡：副币种消费按 1:1 并入本币上限。
    static var dualCurrencyCard: CreditCard { seeded.cards[2] }

    // MARK: - 交易与收入

    static var transactions: [Transaction] { seeded.transactions }

    /// 一笔普通的本币消费。
    static var transaction: Transaction { seeded.transactions[0] }

    /// 带收据图 + 报销记录的交易：详情页里能同时看到收据缩略图和"回血"。
    static var transactionWithReceipt: Transaction { seeded.transactions[1] }

    /// 一笔外币消费（日元入账港币），用来看汇率折算的展示。
    static var foreignTransaction: Transaction { seeded.transactions[2] }

    static var incomes: [Income] { seeded.incomes }
    static var income: Income { seeded.incomes[0] }

    // MARK: - 积分

    static var points: [Point] { seeded.points }
    static var point: Point { seeded.points[0] }
    static var adjustments: [PointAdjustment] { seeded.adjustments }

    /// 积分卡片/详情页用的聚合数据。
    static var pointSummary: PointProgramSummary {
        PointProgramSummary(
            id: point.id.uuidString,
            program: point,
            bankName: point.bankName,
            pointName: point.pointName,
            points: 128_450,
            themeColors: pointsCard.colors
        )
    }

    // MARK: - 银行同步

    static var linkedAccounts: [LinkedBankAccount] { seeded.accounts }

    /// 已匹配到卡片、同步已开启的账户。
    static var linkedAccount: LinkedBankAccount { seeded.accounts[0] }

    /// 没匹配到卡片的账户：用来看"需要手动选卡"的分支。
    static var unmatchedAccount: LinkedBankAccount { seeded.accounts[2] }

    // MARK: - 汇率

    /// 以主货币（默认 CNY）为基准：`金额 / rate` 得到主货币金额。
    static let exchangeRates: [String: Double] = [
        "CNY": 1.0,
        "HKD": 1.09,
        "USD": 0.14,
        "JPY": 21.5,
        "NZD": 0.23,
        "TWD": 4.4,
        "MOP": 1.12,
        "GBP": 0.11,
        "EUR": 0.13
    ]

    // MARK: - 卡片模板

    /// 卡模板管理器（已灌好假模板）。`CardTemplateManager` 只有单例，所以是就地灌数据 ——
    /// 预览进程和 App 进程互不影响，不会写到用户的模板缓存里。
    static let templateManager: CardTemplateManager = {
        let manager = CardTemplateManager.shared
        if manager.templates.isEmpty {
            manager.templates = cardTemplates
        }
        return manager
    }()

    static let cardTemplates: [CardTemplate] = [
        CardTemplate(
            bankName: "招商银行",
            type: "经典白金卡",
            colors: ["1F3A5F", "4A7FB5"],
            region: .cn,
            specialRate: [.dining: 5, .streaming: 3],
            defaultRate: 0.5,
            foreignCurrencyRate: 1.0,
            localBaseCap: 200,
            categoryCaps: [.dining: 100],
            capPeriod: .monthly,
            memo: "餐饮 5% 加成，月上限 100"
        ),
        CardTemplate(
            bankName: "HSBC HK",
            type: "Red Card",
            colors: ["C8102E", "7A0A1C"],
            region: .hk,
            specialRate: [.digital: 3],
            rewardType: .points,
            defaultRate: 1.0,
            foreignCurrencyRate: 2.0,
            memo: "网购 4% RC"
        ),
        CardTemplate(
            bankName: "中银香港",
            type: "双币信用卡",
            colors: ["9C1B24", "D94F45"],
            region: .hk,
            specialRate: [:],
            defaultRate: 0.4,
            foreignCurrencyRate: 1.0,
            secondaryRegion: .cn,
            dualCurrencyMode: .secondaryAsLocal,
            secondaryRate: 0.8
        )
    ]

    static var cardTemplate: CardTemplate { cardTemplates[0] }

    // MARK: - 结单分析

    static var importedTransactions: [ImportedTransaction] {
        let calendar = Calendar.current
        let base = calendar.date(byAdding: .day, value: -20, to: Date()) ?? Date()
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: base) ?? base
        }
        return [
            ImportedTransaction(
                transactionDate: day(0), postDate: day(2), merchant: "STARBUCKS CENTRAL",
                billingAmount: 48.00, region: .hk, paymentMethod: .offline, category: .dining,
                rawText: "05 SEP STARBUCKS CENTRAL 48.00"
            ),
            ImportedTransaction(
                transactionDate: day(3), postDate: day(4), merchant: "APPLE STORE ONLINE",
                billingAmount: 1_299.00, region: .hk, paymentMethod: .online, category: .digital,
                rawText: "08 SEP APPLE STORE ONLINE 1,299.00"
            ),
            ImportedTransaction(
                transactionDate: day(6), postDate: day(8), merchant: "AMAZON JP",
                billingAmount: 512.30, foreignAmount: 8_400, foreignCurrency: "JPY",
                region: .jp, paymentMethod: .online, category: .other,
                rawText: "11 SEP AMAZON JP 8,400 JPY X 0.061"
            ),
            ImportedTransaction(
                transactionDate: day(9), postDate: day(10), merchant: "PARKNSHOP",
                billingAmount: 236.50, region: .hk, paymentMethod: .offline, category: .grocery,
                rawText: "14 SEP PARKNSHOP 236.50"
            )
        ]
    }

    static var statement: StatementMetadata {
        StatementMetadata(
            totalBalance: 2_095.80,
            transactions: importedTransactions,
            statementText: "PREVIEW STATEMENT\nCARD NO **** 1234\nTOTAL 2,095.80",
            cardLast4: "1234",
            cardName: "HSBC HK Red Card"
        )
    }

    /// 一半对上、一半没对上 —— 两种行状态在预览里都能看到。
    static var reconciliationReport: ReconciliationReport {
        let all = importedTransactions
        return ReconciliationReport(
            matched: Array(all.prefix(2)),
            missingInApp: Array(all.dropFirst(2))
        )
    }

    // MARK: - 返现进度

    /// 真实算出来的进度（跟着上面那批交易走）。
    static var capProgress: [CashbackCapProgress] { cashbackCard.cashbackCapProgress() }

    /// 手工造的三种状态：进行中 / 已封顶 / 无上限。
    static let capProgressSamples: [CashbackCapProgress] = [
        CashbackCapProgress(
            id: "dining", title: "餐饮美食", iconName: "cup.and.saucer.fill",
            color: .orange, used: 62, limit: 100
        ),
        CashbackCapProgress(
            id: "base", title: "基础返现", iconName: "creditcard",
            color: .blue, used: 200, limit: 200
        ),
        CashbackCapProgress(
            id: "grocery", title: "超市便利", iconName: "cart.fill",
            color: .green, used: 38, limit: 0
        )
    ]

    // MARK: - 图片

    /// 假收据图：拍照记账、收据全屏这些页面需要一张真的 UIImage。
    static let receiptImage: UIImage = makeReceiptImage()

    /// 假卡面图：`CreditCardView` 传了 cardImageData 时走图片分支而不是渐变。
    static let cardArtData: Data = makeCardArt().jpegData(compressionQuality: 0.9) ?? Data()

    // MARK: - 组装

    private struct Seeded {
        let container: ModelContainer
        let cards: [CreditCard]
        let transactions: [Transaction]
        let incomes: [Income]
        let points: [Point]
        let adjustments: [PointAdjustment]
        let accounts: [LinkedBankAccount]
    }

    private static let seeded: Seeded = makeSeeded()

    private static func makeContainer() -> ModelContainer {
        let schema = Schema([
            Transaction.self, CreditCard.self, Income.self,
            Point.self, PointAdjustment.self, LinkedBankAccount.self
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        // 预览容器建不出来的话什么都看不到，直接崩在这一行比白屏好定位（仅 DEBUG）
        return try! ModelContainer(for: schema, configurations: [config])
    }

    private static func makeSeeded() -> Seeded {
        let container = makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        let now = Date()
        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: now) ?? now
        }

        // ── 积分计划 ──
        let rcPoints = Point(bankName: "HSBC HK", pointName: "RC", pointValue: 1.25, valueCurrencyCode: .hk)
        let urPoints = Point(bankName: "Chase", pointName: "UR", pointValue: 0.015, valueCurrencyCode: .us)
        context.insert(rcPoints)
        context.insert(urPoints)

        // ── 卡片 ──
        let cashback = CreditCard(
            bankName: "招商银行",
            type: "经典白金卡",
            endNum: "6688",
            colorHexes: ["1F3A5F", "4A7FB5"],
            defaultRate: 0.005,
            specialRates: [.dining: 0.05, .streaming: 0.03],
            issueRegion: .cn,
            foreignCurrencyRate: 0.01,
            templateKey: CardTemplate.templateKey(bankName: "招商银行", type: "经典白金卡"),
            localBaseCap: 200,
            foreignBaseCap: 100,
            categoryCaps: [.dining: 100, .streaming: 30],
            capPeriod: .monthly,
            repaymentDay: 18,
            memo: "预览示例：餐饮 5%，月上限 100",
            paymentMethodRates: [.applePay: 0.01],
            paymentCaps: [.applePay: 50]
        )
        cashback.sortIndex = 0

        let pointsCard = CreditCard(
            bankName: "HSBC HK",
            type: "Red Card",
            endNum: "1234",
            colorHexes: ["C8102E", "7A0A1C"],
            defaultRate: 0.01,
            specialRates: [.digital: 0.03],
            issueRegion: .hk,
            foreignCurrencyRate: 0.02,
            localBaseCap: 0,
            repaymentDay: 6,
            rewardType: .points,
            pointProgram: rcPoints
        )
        pointsCard.sortIndex = 1

        let dualCard = CreditCard(
            bankName: "中银香港",
            type: "双币信用卡",
            endNum: "8899",
            colorHexes: ["9C1B24", "D94F45"],
            defaultRate: 0.004,
            specialRates: [.travel: 0.02],
            issueRegion: .hk,
            foreignCurrencyRate: 0.01,
            localBaseCap: 500,
            capPeriod: .yearly,
            repaymentDay: 25,
            secondaryRegion: .cn,
            dualCurrencyMode: .secondaryAsLocal,
            secondaryRate: 0.008
        )
        dualCard.sortIndex = 2

        let cards = [cashback, pointsCard, dualCard]
        cards.forEach(context.insert)

        // ── 交易 ──
        // 跨几个月铺开，趋势图和月度上限都有东西可看
        let plain = Transaction(
            merchant: "星巴克 国金中心",
            category: .dining,
            location: .cn,
            amount: 68,
            date: daysAgo(1),
            card: cashback,
            paymentMethod: .applePay
        )
        let withReceipt = Transaction(
            merchant: "山姆会员店",
            category: .grocery,
            location: .cn,
            amount: 486.50,
            date: daysAgo(3),
            card: cashback,
            receiptData: receiptImage.jpegData(compressionQuality: 0.8),
            paymentMethod: .offline
        )
        let foreign = Transaction(
            merchant: "Amazon JP",
            category: .digital,
            location: .jp,
            amount: 8_400,
            date: daysAgo(6),
            card: pointsCard,
            billingAmount: 512.30,
            pointsEarned: 512,
            paymentMethod: .online,
            billingCurrencyCode: "HKD"
        )
        let others: [Transaction] = [
            Transaction(merchant: "Netflix", category: .streaming, location: .cn, amount: 35,
                        date: daysAgo(12), card: cashback, paymentMethod: .online),
            Transaction(merchant: "京东", category: .digital, location: .cn, amount: 1_299,
                        date: daysAgo(20), card: cashback, paymentMethod: .online),
            Transaction(merchant: "PARKNSHOP", category: .grocery, location: .hk, amount: 236.50,
                        date: daysAgo(34), card: pointsCard, pointsEarned: 236, paymentMethod: .offline),
            Transaction(merchant: "国泰航空", category: .travel, location: .hk, amount: 3_280,
                        date: daysAgo(48), card: dualCard, paymentMethod: .online),
            Transaction(merchant: "深圳地铁", category: .travel, location: .cn, amount: 12,
                        date: daysAgo(52), card: dualCard, billingAmount: 12,
                        paymentMethod: .qrCode, billingCurrencyCode: "CNY"),
            Transaction(merchant: "Uniqlo 银座", category: .other, location: .jp, amount: 12_800,
                        date: daysAgo(75), card: pointsCard, billingAmount: 680,
                        pointsEarned: 680, paymentMethod: .offline, billingCurrencyCode: "HKD"),
            // Plaid 同步进来的那一笔：来源相关的分支靠它
            Transaction(merchant: "WHOLE FOODS MKT", category: .grocery, location: .us, amount: 82.14,
                        date: daysAgo(9), card: pointsCard, billingAmount: 640.70,
                        paymentMethod: .offline, billingCurrencyCode: "HKD", source: .plaid)
        ]
        let transactions = [plain, withReceipt, foreign] + others
        transactions.forEach(context.insert)

        // ── 收入（报销 / 回血）──
        let incomes = [
            Income(amount: 200, date: daysAgo(2), location: .cn, transaction: withReceipt,
                   detail: "公司团建报销", platform: "钉钉", isReceived: true),
            Income(amount: 30, date: daysAgo(1), location: .cn, transaction: plain,
                   detail: "同事分摊", platform: "微信", isReceived: false)
        ]
        incomes.forEach(context.insert)

        // ── 积分调整 ──
        let adjustments = [
            PointAdjustment(pointProgram: rcPoints, points: 60_000, date: daysAgo(120),
                            type: .bonus, note: "开卡礼"),
            PointAdjustment(pointProgram: rcPoints, points: -25_000, date: daysAgo(30),
                            type: .redeem, note: "换 HKD 250 现金券"),
            PointAdjustment(pointProgram: urPoints, points: 80_000, date: daysAgo(200),
                            type: .bonus, note: "Sapphire 开卡奖励")
        ]
        adjustments.forEach(context.insert)

        // ── 已绑定的银行账户 ──
        // 前两个同属一个 item（同一家银行两张卡），第三个没匹配到卡片
        let accounts = [
            LinkedBankAccount(itemId: "item-chase-001", accountId: "acc-001",
                              institutionName: "Chase", accountName: "Sapphire Preferred",
                              mask: "1234", card: pointsCard, syncEnabled: true),
            LinkedBankAccount(itemId: "item-chase-001", accountId: "acc-002",
                              institutionName: "Chase", accountName: "Freedom Unlimited",
                              mask: "6688", card: cashback, syncEnabled: true),
            LinkedBankAccount(itemId: "item-boc-002", accountId: "acc-003",
                              institutionName: "Bank of China (HK)", accountName: "Dual Currency",
                              mask: "0000")
        ]
        accounts[0].lastSyncedAt = daysAgo(1)
        accounts[0].didInitialSync = true
        accounts[1].lastSyncedAt = daysAgo(1)
        accounts[1].didInitialSync = true
        accounts.forEach(context.insert)

        try? context.save()

        return Seeded(
            container: container,
            cards: cards,
            transactions: transactions,
            incomes: incomes,
            points: [rcPoints, urPoints],
            adjustments: adjustments,
            accounts: accounts
        )
    }

    // MARK: - 图片生成

    private static func makeReceiptImage() -> UIImage {
        let size = CGSize(width: 320, height: 460)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 20),
                .foregroundColor: UIColor.black
            ]
            "山姆会员店\nSAM'S CLUB".draw(
                in: CGRect(x: 20, y: 24, width: 280, height: 60),
                withAttributes: titleAttrs
            )

            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor.darkGray
            ]
            let lines = """
            ------------------------------
            牛奶 1L x2              59.80
            车厘子 2lb             168.00
            三文鱼                  98.70
            厨房纸 6卷              60.00
            坚果礼盒               100.00
            ------------------------------
            合计                   486.50
            VISA ****6688
            """
            lines.draw(in: CGRect(x: 20, y: 100, width: 280, height: 260), withAttributes: bodyAttrs)

            // 底部假条码
            UIColor.black.setStroke()
            for i in 0..<28 {
                let path = UIBezierPath()
                let x = 24 + CGFloat(i) * 10
                path.move(to: CGPoint(x: x, y: 380))
                path.addLine(to: CGPoint(x: x, y: 430))
                path.lineWidth = i.isMultiple(of: 3) ? 3 : 1
                path.stroke()
            }
        }
    }

    private static func makeCardArt() -> UIImage {
        let size = CGSize(width: 640, height: 400)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [
                UIColor(red: 0.10, green: 0.18, blue: 0.35, alpha: 1).cgColor,
                UIColor(red: 0.35, green: 0.20, blue: 0.55, alpha: 1).cgColor
            ]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            UIColor.white.withAlphaComponent(0.12).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 420, y: -80, width: 320, height: 320))

            "PREVIEW".draw(
                at: CGPoint(x: 36, y: 300),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 40, weight: .heavy),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.85)
                ]
            )
        }
    }
}

// MARK: - 预览环境

@MainActor
extension View {

    /// 挂上预览用的内存数据库和卡模板管理器。
    ///
    /// 带 `@Query`、`@Environment(\.modelContext)` 或 `@Environment(CardTemplateManager.self)`
    /// 的视图都要用它 —— 少挂了轻则空列表，重则 SwiftUI 直接崩在缺少 environment 上。
    ///
    /// - Parameter onboardingSeen: 传了才会去动 `hasSeenOnboarding`。ContentView 会在这个
    ///   开关为 false 时被引导页整页盖住，所以只有明确想看某一侧的预览才该传值。
    func previewEnvironment(onboardingSeen: Bool? = nil) -> some View {
        if let onboardingSeen {
            UserDefaults.standard.set(onboardingSeen, forKey: "hasSeenOnboarding")
        }
        return modelContainer(PreviewData.container)
            .environment(PreviewData.templateManager)
    }

    /// 同上，但数据库是空的：专门看空状态分支。
    func previewEmptyEnvironment() -> some View {
        modelContainer(PreviewData.emptyContainer)
            .environment(PreviewData.templateManager)
    }
}

#endif
