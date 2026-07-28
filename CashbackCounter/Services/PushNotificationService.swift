//
//  PushNotificationService.swift
//  CashbackCounter
//
//  远程推送（APNs）的注册与令牌上报。
//
//  当前只用**可见推送**：银行有新交易时后端推一条「{银行名} 有新交易」。
//  刻意不做静默推送触发同步 —— 同步严格保持"每天第一次打开 App 时一次"，
//  通知只负责告诉你"有事发生了"，不负责把数据拉下来。
//
//  为什么不用静默推送：iOS 对 background push 是**尽力而为**的，
//  低电量、系统预算不足、用户杀掉 App 都可能不送达。用它做通知会时有时无，
//  而用户对"通知"的预期是必达。可见推送（apns-push-type: alert）没有这个问题。
//

import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor
@Observable
final class PushNotificationService: NSObject {

    static let shared = PushNotificationService()

    private let api = PlaidAPIClient.shared

    /// 系统给的设备令牌。可能在用户登录**之前**就拿到，所以要先存着。
    private var deviceToken: String?
    /// 已经成功上报给后端的那个令牌，避免每次回前台都重复上报
    private var uploadedToken: String?

    private override init() {
        super.init()
    }

    // MARK: - 注册

    /// 向 APNs 注册。拿到令牌会走 AppDelegate 的回调。
    ///
    /// 注册本身不需要通知权限 —— 没权限也拿得到令牌，只是通知不会显示。
    /// 权限由 NotificationManager 在 App 启动时申请（还款提醒也要用）。
    func register() {
        UNUserNotificationCenter.current().delegate = self
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// AppDelegate 拿到令牌后调这里
    func didRegister(deviceToken data: Data) {
        // APNs 给的是二进制，后端要的是十六进制字符串
        let token = data.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = token
        Task { await uploadIfNeeded() }
    }

    func didFailToRegister(error: Error) {
        // 模拟器上没有真正的 APNs，这里必然失败，属于正常现象
        print("⚠️ 注册远程推送失败：\(error.localizedDescription)")
    }

    // MARK: - 上报

    /// 把令牌上报给后端。
    ///
    /// 三种时机都要调：拿到令牌时、登录成功后、回到前台时。
    /// 因为令牌和登录状态谁先谁后都有可能 —— 令牌可能在用户还没登录时就到了，
    /// 而那时上报会因为没有会话 token 而失败。
    func uploadIfNeeded() async {
        guard AuthService.shared.isSignedIn,
              let deviceToken,
              deviceToken != uploadedToken else {
            return
        }

        do {
            let _: EmptyResponse = try await api.post(
                "/api/plaid/device-token",
                body: DeviceTokenRequest(apnsToken: deviceToken, environment: Self.apnsEnvironment))
            uploadedToken = deviceToken
            // 环境一定要打出来：推送不工作时第一个要确认的就是它有没有搞反
            print("✅ 设备令牌已上报，APNs 环境=\(Self.apnsEnvironment)")
        } catch {
            // 上报失败不影响任何其它功能，下次回前台会再试
            print("⚠️ 上报设备令牌失败：\(error.localizedDescription)")
        }
    }

    /// 退出登录时清掉，下次登录（可能是另一个账号）会重新上报
    func reset() {
        uploadedToken = nil
    }

    /// APNs 的沙盒和生产是**两套独立网关，令牌互不通用**。
    /// 后端同时服务 debug 和 TestFlight 构建，猜不出来，只能由 App 告诉它。
    ///
    /// **不用 `#if DEBUG` 判断**，而是去读描述文件里真正的 `aps-environment`。
    /// 因为决定令牌属于哪一套的是 entitlement，不是编译配置 —— 两者不一致的情况
    /// 完全可能发生（entitlements 文件写死 development、用 Release 配置真机调试、
    /// 手动签名用了不匹配的描述文件……）。
    ///
    /// 猜错的后果是**静默的**：APNs 只会回一个 400 BadDeviceToken 给后端，
    /// 用户侧的表现就是"推送没了"，没有任何线索。所以宁可多读一次文件。
    static var apnsEnvironment: String {
        if let fromProfile = environmentFromProvisioningProfile() {
            return fromProfile
        }
        // App Store 分发的包可能不含描述文件，那时只能靠编译配置兜底
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// 从 embedded.mobileprovision 里抠出 `Entitlements.aps-environment`。
    ///
    /// 这个文件是 CMS 签名的二进制，中间夹着一段明文 plist。
    /// 不引三方库的做法：在字节流里定位 `<plist` 到 `</plist>` 这一段直接解析。
    private static func environmentFromProvisioningProfile() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex) else {
            return nil
        }

        let plistData = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let apsEnvironment = entitlements["aps-environment"] as? String else {
            return nil
        }

        // entitlement 的取值是 development / production，正好和后端要的一致，
        // 只把 development 翻译成 sandbox
        return apsEnvironment == "development" ? "sandbox" : "production"
    }
}

// MARK: - 通知展示

extension PushNotificationService: UNUserNotificationCenterDelegate {

    /// App 在前台时也把通知显示出来。
    ///
    /// 系统默认在前台**不显示**横幅。但"银行有新交易"这条恰恰在用户正用着 App 时
    /// 也有意义，静默吞掉会让人以为推送坏了。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// 用户点开通知。
    ///
    /// **刻意什么都不做**（除了打开 App）：同步严格保持每天一次，
    /// 点通知不会触发额外的拉取。想立刻看到，去「银行同步」页下拉刷新。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        print("ℹ️ 用户点开推送通知: itemId=\(info["itemId"] ?? "-")")
    }
}

private struct DeviceTokenRequest: Encodable {
    let apnsToken: String
    let environment: String

    enum CodingKeys: String, CodingKey {
        case apnsToken = "apns_token"
        case environment
    }
}
