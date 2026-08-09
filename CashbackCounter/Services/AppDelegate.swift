//
//  AppDelegate.swift
//  CashbackCounter
//
//  只为一件事存在：APNs 的设备令牌**只能**通过 UIApplicationDelegate 的回调拿到，
//  SwiftUI 没有等价的接口。所以接一个最小的 delegate，转手交给
//  PushNotificationService，不在这里放任何业务逻辑。
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 注册要尽早，令牌才能在用户走到需要它的地方之前就到位
        Task { @MainActor in
            PushNotificationService.shared.register()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushNotificationService.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationService.shared.didFailToRegister(error: error)
        }
    }

    /// 推送把 App 从后台唤醒 —— 立刻拉取该 item 的新交易。
    ///
    /// 后端在「有新交易」那条推送里带了 `content-available: 1`，系统才会调到这里。
    /// 于是用户点开通知时，交易**已经在 App 里**了，不用等到第二天的每日同步。
    ///
    /// ⚠️ 必须调 completionHandler 并如实汇报结果：iOS 用它来决定以后还要不要
    /// 继续唤醒这个 App。长期返回 .noData 会被系统降低唤醒频率。
    /// 也必须尽快返回 —— 系统给的后台执行时间只有大约 30 秒。
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await PushNotificationService.shared.syncOnRemoteNotification(userInfo: userInfo)
    }
}
