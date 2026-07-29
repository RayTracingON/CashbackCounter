//
//  CashbackCounterApp.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import SwiftData

@main // 👈 1. 这里的 @main 就相当于 Java 的 public static void main()。
      // 它告诉系统：程序从这里开始跑！
struct CashbackCounterApp: App { // 2. 这个结构体必须遵守 App 协议
    @AppStorage("userTheme") private var userTheme: Int = 0
    @AppStorage("userLanguage") private var userLanguage: String = "system"
    
    // 与 App Intents（快捷指令）共用同一个容器，见 SharedModelContainer
    let container: ModelContainer = SharedModelContainer.shared

    /// APNs 设备令牌只能从 UIApplicationDelegate 的回调拿到，SwiftUI 没有等价接口
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NotificationManager.shared.requestAuthorization()
        // 要在任何 await 之前挂上 Transaction.updates 的监听：
        // 续订、退款、别的设备上的购买都只从那个流里来，晚挂就会漏。
        SubscriptionManager.shared.start()
    }
    
    @Environment(\.scenePhase) private var scenePhase

    /// 自动同步的节奏：**每个自然日第一次打开 App 时同步一次**。
    ///
    /// 用"是不是今天同步过"而不是"距上次超过 N 小时"，是因为前者对用户是可解释的
    /// ——「每天一次」谁都懂，而「6 小时」会让人困惑于为什么早上刷了下午不刷。
    /// 想立刻拿到最新数据，「银行同步」页下拉刷新随时可以强制拉一次。
    ///
    /// 注意用的是本地日历：跨时区旅行时"今天"跟着用户走，这正是想要的。
    @MainActor
    private func syncIfNeededToday() async {
        guard AuthService.shared.isSignedIn else { return }

        let context = container.mainContext
        let accounts = (try? context.fetch(FetchDescriptor<LinkedBankAccount>())) ?? []
        let syncable = accounts.filter(\.isSyncable)
        guard !syncable.isEmpty else { return }

        // 有任何一张卡从没同步过，或者最近一次同步不是今天
        let needsSync = syncable.contains { account in
            guard let last = account.lastSyncedAt else { return true }
            return !Calendar.current.isDateInToday(last)
        }
        guard needsSync else { return }

        await PlaidSyncService.shared.syncAll(context: context)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(CardTemplateManager.shared)
                .preferredColorScheme(userTheme == 1 ? .light : (userTheme == 2 ? .dark : nil))
                .environment(\.locale, userLanguage == "system" ? .current : Locale(identifier: userLanguage))
                .task {
                    // 用户可能在系统设置里撤销了本 App 的 Apple ID 授权，
                    // 也可能换了设备。撤销了就本地登出，避免 UI 显示"已登录"
                    // 但每个请求都 401 的错乱状态。
                    await AuthService.shared.refreshCredentialState()
                    // 令牌和登录状态谁先到都有可能，两边都要触发一次上报
                    await PushNotificationService.shared.uploadIfNeeded()
                    await syncIfNeededToday()
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, newPhase in
            // 回前台时再核对一次：撤销授权发生在系统设置里，
            // App 在后台时不会收到任何通知。
            if newPhase == .active {
                Task {
                    await AuthService.shared.refreshCredentialState()
                    await PushNotificationService.shared.uploadIfNeeded()
                    await syncIfNeededToday()
                }
            }
        }
    }
}
