import UserNotifications
import UIKit

class NotificationManager {
    static let shared = NotificationManager()

    /// 还款提醒通知的 identifier 前缀，用于区分本 App 注册的通知
    private static let reminderIDPrefix = "repayment_"

    /// 还款日 ≥ 29 的卡不能用"每月重复"的触发器：`UNCalendarNotificationTrigger(day: 31, repeats: true)`
    /// 只在有 31 号的月份触发，2/4/6/9/11 月整月静默；30 号在 2 月、29 号在平年 2 月同理。
    /// 这些卡改为**按月滚动**注册：未来 12 个月各一条一次性提醒，日子取 min(还款日, 当月天数)，
    /// 每次启动补齐（见 refreshRollingReminders）。
    static let rollingThreshold = 29
    static let rollingMonths = 12

    /// 根据卡片身份信息生成稳定的通知 identifier。
    /// 注意：不能用 hashValue，Swift 的哈希种子每次启动都不同，会导致重启后无法取消旧通知。
    static func reminderIdentifier(for card: CreditCard) -> String {
        let bank = card.bankName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = card.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let endNum = card.endNum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(reminderIDPrefix)\(bank)|\(type)|\(endNum)"
    }

    /// 滚动提醒的触发时间：从本月起连续 N 个月，每月 min(还款日, 当月天数) 的 9:00，已过去的跳过
    static func rollingReminderComponents(repaymentDay: Int,
                                          from now: Date = Date(),
                                          months: Int = rollingMonths,
                                          calendar: Calendar = .current) -> [DateComponents] {
        guard let firstMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) else { return [] }
        var result: [DateComponents] = []
        var monthStart = firstMonth
        for _ in 0..<months {
            let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 28
            var comps = calendar.dateComponents([.year, .month], from: monthStart)
            comps.day = min(repaymentDay, daysInMonth)
            comps.hour = 9
            comps.minute = 0
            if let fire = calendar.date(from: comps), fire > now {
                result.append(comps)
            }
            guard let next = calendar.date(byAdding: .month, value: 1, to: monthStart) else { break }
            monthStart = next
        }
        return result
    }

    /// 滚动提醒的 identifier：固定 identifier 后接年月
    static func rollingIdentifier(base: String, components: DateComponents) -> String {
        String(format: "%@|%04d%02d", base, components.year ?? 0, components.month ?? 0)
    }

    /// 取消时要覆盖的全部 identifier：固定那条 + 上个月到未来 13 个月的滚动条目。
    /// 列表是算出来的而不是去查 pending 列表：查询是异步的，紧接着的 add 可能排在删除之前，
    /// 刚注册的那条会被自己删掉。
    static func identifiersToCancel(for card: CreditCard, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        let base = reminderIdentifier(for: card)
        var ids = [base]
        guard let start = calendar.date(byAdding: .month, value: -1, to: now) else { return ids }
        for offset in 0..<(rollingMonths + 2) {
            guard let month = calendar.date(byAdding: .month, value: offset, to: start) else { continue }
            ids.append(rollingIdentifier(base: base, components: calendar.dateComponents([.year, .month], from: month)))
        }
        return ids
    }

    // 1. 请求权限
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ 通知权限已获取")
            } else {
                print("❌ 通知权限被拒绝")
            }
        }
    }

    // 2. 为卡片注册/更新通知
    func scheduleNotification(for card: CreditCard) {
        // 先取消旧的（防止重复）
        cancelNotification(for: card)

        // 如果还款日无效 (0)，则不注册
        guard card.isRemindOpen, card.repaymentDay > 0, card.repaymentDay <= 31 else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String.loc("还款提醒: \(card.bankName) \(card.type)")
        content.body = String.loc("今天是这张卡的还款日，别忘了处理账单哦！")
        content.sound = .default

        let identifier = Self.reminderIdentifier(for: card)
        let center = UNUserNotificationCenter.current()

        if card.repaymentDay >= Self.rollingThreshold {
            // 29/30/31：按月滚动，每月一条一次性提醒
            let schedule = Self.rollingReminderComponents(repaymentDay: card.repaymentDay)
            for comps in schedule {
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let request = UNNotificationRequest(
                    identifier: Self.rollingIdentifier(base: identifier, components: comps),
                    content: content, trigger: trigger)
                center.add(request) { error in
                    if let error { print("❌ 通知注册失败: \(error)") }
                }
            }
            print("✅ 已设定每月 \(card.repaymentDay) 日（短月取月末）提醒，共 \(schedule.count) 条: \(card.bankName)")
            return
        }

        // 设置触发时间：每月的这一天，早上 9:00
        var dateComponents = DateComponents()
        dateComponents.day = card.repaymentDay
        dateComponents.hour = 9
        dateComponents.minute = 0

        // repeats: true 代表每个月重复
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        center.add(request) { error in
            if let error = error {
                print("❌ 通知注册失败: \(error)")
            } else {
                print("✅ 已设定每月 \(card.repaymentDay) 日提醒: \(card.bankName)")
            }
        }
    }

    // 3. 取消通知 (用于删除卡片或关闭提醒时)
    func cancelNotification(for card: CreditCard) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: Self.identifiersToCancel(for: card))
    }

    /// 每次启动把滚动提醒补齐到未来 12 个月（只处理还款日 ≥ 29 的卡）。
    /// 需在主线程调用（card 是 SwiftData 模型）。
    func refreshRollingReminders(cards: [CreditCard]) {
        for card in cards where card.isRemindOpen && card.repaymentDay >= Self.rollingThreshold {
            scheduleNotification(for: card)
        }
    }

    /// 一次性迁移：清掉旧版 hashValue identifier 留下的孤儿通知，并按新 identifier 重新注册。
    /// 需在主线程调用（card 是 SwiftData 模型）。
    func migrateLegacyReminders(cards: [CreditCard]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let legacyIDs = requests
                .map(\.identifier)
                .filter { !$0.hasPrefix(Self.reminderIDPrefix) }
            if !legacyIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: legacyIDs)
                print("🧹 已清理 \(legacyIDs.count) 条旧版还款提醒")
            }
            DispatchQueue.main.async {
                for card in cards where card.isRemindOpen && card.repaymentDay > 0 {
                    self.scheduleNotification(for: card)
                }
            }
        }
    }
}
