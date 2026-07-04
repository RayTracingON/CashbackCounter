import UserNotifications
import UIKit

class NotificationManager {
    static let shared = NotificationManager()

    /// 还款提醒通知的 identifier 前缀，用于区分本 App 注册的通知
    private static let reminderIDPrefix = "repayment_"

    /// 根据卡片身份信息生成稳定的通知 identifier。
    /// 注意：不能用 hashValue，Swift 的哈希种子每次启动都不同，会导致重启后无法取消旧通知。
    static func reminderIdentifier(for card: CreditCard) -> String {
        let bank = card.bankName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = card.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let endNum = card.endNum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(reminderIDPrefix)\(bank)|\(type)|\(endNum)"
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
        content.title = "还款提醒: \(card.bankName) \(card.type)"
        content.body = "今天是这张卡的还款日，别忘了处理账单哦！"
        content.sound = .default

        // 设置触发时间：每月的这一天，早上 9:00
        var dateComponents = DateComponents()
        dateComponents.day = card.repaymentDay
        dateComponents.hour = 9
        dateComponents.minute = 0

        // repeats: true 代表每个月重复
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let identifier = Self.reminderIdentifier(for: card)

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ 通知注册失败: \(error)")
            } else {
                print("✅ 已设定每月 \(card.repaymentDay) 日提醒: \(card.bankName)")
            }
        }
    }

    // 3. 取消通知 (用于删除卡片或关闭提醒时)
    func cancelNotification(for card: CreditCard) {
        let identifier = Self.reminderIdentifier(for: card)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
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
