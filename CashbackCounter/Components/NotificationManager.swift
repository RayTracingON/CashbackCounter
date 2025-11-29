import UserNotifications
import UIKit

class NotificationManager {
    static let shared = NotificationManager()
    
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
        
        // 使用卡片的 id 作为通知的唯一标识符
        // 注意：PersistentIdentifier 转 string 比较长，这里转一下
        let identifier = card.id.hashValue.description
        
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
        let identifier = card.id.hashValue.description
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
