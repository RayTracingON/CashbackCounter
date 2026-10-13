import XCTest
import SwiftData
@testable import CashbackCounter

private typealias Transaction = CashbackCounter.Transaction

/// 体验 / 稳定类修复（审查报告第三组）里能用纯逻辑守住的部分：
///
///   · 还款日 29/30/31 按月滚动注册，短月取月末，已过去的跳过，取消列表覆盖所有注册项
///   · 绑定后一周内每天再全量拉一次 Plaid 历史
///   · 汇率缓存按 base 分槽，旧的单槽缓存能迁移
///   · 首页统计缺任何一个币种的汇率时返回 nil（显示 "..."）而不是按 1:1 算
@MainActor
final class StabilityFixesTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 8) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    // MARK: - 还款提醒

    func testRollingRemindersClampToMonthLength() {
        let comps = NotificationManager.rollingReminderComponents(
            repaymentDay: 31, from: date(2026, 1, 1), months: 4, calendar: calendar)
        XCTAssertEqual(comps.map(\.month), [1, 2, 3, 4])
        XCTAssertEqual(comps.map(\.day), [31, 28, 31, 30], "2026 年 2 月取 28、4 月取 30")
        XCTAssertTrue(comps.allSatisfy { $0.hour == 9 && $0.minute == 0 })
    }

    func testRollingRemindersHandleLeapYear() {
        let comps = NotificationManager.rollingReminderComponents(
            repaymentDay: 30, from: date(2028, 2, 1), months: 1, calendar: calendar)
        XCTAssertEqual(comps.first?.day, 29, "闰年 2 月取 29")
    }

    func testRollingRemindersSkipDatesAlreadyPassed() {
        // 1 月 31 日 10:00 启动：当月 9:00 那条已过去，从 2 月开始
        let comps = NotificationManager.rollingReminderComponents(
            repaymentDay: 30, from: date(2026, 1, 31, hour: 10), months: 3, calendar: calendar)
        XCTAssertEqual(comps.map(\.month), [2, 3])
        XCTAssertEqual(comps.first?.day, 28)
    }

    func testCancelListCoversEveryRegisteredRollingReminder() {
        let card = CreditCard(bankName: "HSBC", type: "Red", endNum: "1234", colorHexes: ["000000"],
                              defaultRate: 0.01, specialRates: [:], issueRegion: .hk, repaymentDay: 31)
        let now = date(2026, 1, 1)
        let ids = NotificationManager.identifiersToCancel(for: card, now: now, calendar: calendar)
        let base = NotificationManager.reminderIdentifier(for: card)

        XCTAssertEqual(ids.first, base, "固定那条也要在取消列表里")
        XCTAssertEqual(ids.count, 1 + NotificationManager.rollingMonths + 2)
        XCTAssertTrue(ids.contains("\(base)|202512"), "上个月的残留也要能取消")

        for comps in NotificationManager.rollingReminderComponents(repaymentDay: 31, from: now, calendar: calendar) {
            let id = NotificationManager.rollingIdentifier(base: base, components: comps)
            XCTAssertTrue(ids.contains(id), "\(id) 注册了却不在取消列表里")
        }
    }

    // MARK: - Plaid 历史补拉

    func testFullPullRepeatsDailyDuringFirstWeekOnly() {
        let defaults = UserDefaults(suiteName: "StabilityFixesTests.\(UUID().uuidString)")!
        let account = LinkedBankAccount(itemId: "item", accountId: "acct",
                                        institutionName: "Chase", accountName: "Freedom", mask: "1234")
        let now = date(2026, 6, 10)
        account.linkedAt = now.addingTimeInterval(-24 * 3600)

        account.didInitialSync = false
        XCTAssertFalse(PlaidSyncService.shouldRepeatFullPull(for: account, now: now, defaults: defaults),
                       "首次全量还没做过时走的是 needsInitial，不归这里管")

        account.didInitialSync = true
        XCTAssertTrue(PlaidSyncService.shouldRepeatFullPull(for: account, now: now, defaults: defaults),
                      "绑定一天、从没补拉过 → 要拉")

        PlaidSyncService.recordFullPull(for: account, at: now.addingTimeInterval(-3600), defaults: defaults)
        XCTAssertFalse(PlaidSyncService.shouldRepeatFullPull(for: account, now: now, defaults: defaults),
                       "一小时前刚拉过 → 不拉")
        XCTAssertTrue(PlaidSyncService.shouldRepeatFullPull(
            for: account, now: now.addingTimeInterval(21 * 3600), defaults: defaults), "超过 20 小时 → 再拉")

        account.linkedAt = now.addingTimeInterval(-10 * 24 * 3600)
        XCTAssertFalse(PlaidSyncService.shouldRepeatFullPull(for: account, now: now, defaults: defaults),
                       "绑定超过一周 → 只走增量")
    }

    // MARK: - 汇率缓存

    func testCurrencyCacheIsKeyedByBase() {
        let suite = UserDefaults(suiteName: "StabilityFixesTests.rates.\(UUID().uuidString)")!
        CurrencyService.defaults = suite
        defer { CurrencyService.defaults = .standard }

        CurrencyService.store(["usd": 0.14], for: "CNY")
        CurrencyService.store(["cny": 7.1], for: "USD")

        XCTAssertEqual(CurrencyService.cachedEntry(for: "cny")?.rates["USD"], 0.14, "大小写都能查")
        XCTAssertEqual(CurrencyService.cachedEntry(for: "USD")?.rates["cny"], 7.1)
        XCTAssertNotNil(CurrencyService.cachedEntry(for: "CNY"), "存第二个 base 不能挤掉第一个")

        CurrencyService.store(["jpy": 20], for: "CNY", at: Date(timeIntervalSinceNow: -2 * 86400))
        let stale = CurrencyService.cachedEntry(for: "CNY")!
        XCTAssertFalse(CurrencyService.isFresh(stale), "前天的缓存不算新鲜，但仍可作离线兜底")
        XCTAssertEqual(stale.rates["JPY"], 20)
    }

    func testLegacySingleSlotCacheIsMigrated() throws {
        let suite = UserDefaults(suiteName: "StabilityFixesTests.legacy.\(UUID().uuidString)")!
        CurrencyService.defaults = suite
        defer { CurrencyService.defaults = .standard }

        suite.set(try JSONEncoder().encode(CachedRates(base: "HKD", rates: ["CNY": 0.92])),
                  forKey: AppConfig.UserDefaultsKey.cachedExchangeRates)
        suite.set(Date(), forKey: AppConfig.UserDefaultsKey.lastFetchDate)

        let entry = try XCTUnwrap(CurrencyService.cachedEntry(for: "HKD"))
        XCTAssertEqual(entry.rates["cny"], 0.92)
        XCTAssertTrue(CurrencyService.isFresh(entry))
    }

    // MARK: - 首页统计

    func testTotalsAreUnavailableWhenAnyRateIsMissing() throws {
        let schema = Schema([Transaction.self, CreditCard.self, Income.self, Point.self, PointAdjustment.self, LinkedBankAccount.self])
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)

        let card = CreditCard(bankName: "B", type: "T", endNum: "0001", colorHexes: ["000000"],
                              defaultRate: 0.01, specialRates: [:], issueRegion: .hk)
        context.insert(card)
        let tx = Transaction(merchant: "Lawson", category: .other, location: .jp, amount: 1000,
                             date: Date(), card: card, billingAmount: 1000, cashbackAmount: 10,
                             billingCurrencyCode: "JPY")
        context.insert(tx)

        let vm = BillHomeViewModel()
        vm.exchangeRates = ["CNY": 1.0, "HKD": 1.1]
        XCTAssertNil(vm.totalExpense(from: [tx], mainCurrencyCode: "CNY"), "缺 JPY 汇率时不能按 1:1 算成 ¥1000")
        XCTAssertNil(vm.totalCashback(from: [tx], mainCurrencyCode: "CNY"))

        vm.exchangeRates["JPY"] = 20
        XCTAssertEqual(try XCTUnwrap(vm.totalExpense(from: [tx], mainCurrencyCode: "CNY")), 50, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(vm.totalCashback(from: [tx], mainCurrencyCode: "CNY")), 0.5, accuracy: 0.0001)

        vm.exchangeRates = [:]
        XCTAssertNil(vm.totalExpense(from: [tx], mainCurrencyCode: "CNY"), "汇率还没到 → \"...\"")
    }
}
