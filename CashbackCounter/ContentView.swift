import SwiftUI
import SwiftData

// --- 2. 主入口 (包含底部导航栏) ---
struct ContentView: View {
    // 选中的 Tab 索引
    // 用 @AppStorage 而不是 @State：切语言时整棵树会按 id 重建（见 CashbackCounterApp），
    // @State 会被一起丢掉，把刚在设置页操作的用户弹回账单页。
    @AppStorage("selectedTab") private var selectedTab = AppTab.bills.rawValue
    @Environment(\.modelContext) private var context
    @AppStorage(OnboardingTour.seenKey) private var hasSeenOnboarding = false
    @State private var tour = OnboardingTour.shared
    /// 启动时发现本地数据库打不开、已被挪到备份目录重建：只提示一次
    @State private var storeRecoveryNotice: SharedModelContainer.RecoveryNotice? = SharedModelContainer.recoveryNotice

    var body: some View {
        // TabView 是底部导航栏的核心容器
        TabView(selection: $selectedTab) {

            // --- 左边：账单页 ---
            BillHomeView()
                .tourTabContent()
                .tabItem {
                    Image(systemName: selectedTab == AppTab.bills.rawValue ? "doc.text.image.fill" : "doc.text.image")
                    Text("账单")
                }
                .tag(AppTab.bills.rawValue)

            CardListView()
                .tourTabContent()
                .tabItem {
                    Image(systemName: selectedTab == AppTab.cards.rawValue ? "creditcard.fill" : "creditcard")
                    Text("卡包")
                }
                .tag(AppTab.cards.rawValue)

            CameraRecordView()
                .tourTabContent()
                .tabItem {
                    Image(systemName: "camera.circle.fill") // 大圆圈图标
                    Text("拍一笔")
                }
                .tag(AppTab.camera.rawValue)

            // --- 积分系统页 ---
            PointSystemView()
                .tourTabContent()
                .tabItem {
                    Image(systemName: selectedTab == AppTab.points.rawValue ? "star.circle.fill" : "star.circle")
                    Text("积分")
                }
                .tag(AppTab.points.rawValue)

            // --- ✨ 新增：设置页 ---
            SettingsView()
                .tourTabContent()
                .tabItem {
                    // 选中时变成实心齿轮
                    Image(systemName: selectedTab == AppTab.settings.rawValue ? "gearshape.fill" : "gearshape")
                    Text("设置")
                }
                .tag(AppTab.settings.rawValue)
        }
        .tint(.blue) // 设置底部选中时的颜色 (Apple 蓝)
        // 新手导览直接叠在真实界面上（盖住 TabBar，导览途中不会误切走）
        .tourOverlayHost(.main)
        .onChange(of: tour.step) { _, step in
            if let tab = step?.tab {
                selectedTab = tab.rawValue
            } else if step == nil {
                // 导览结束（含跳过）才问通知权限，见 CashbackCounterApp.init。
                // 系统只会弹一次，重看导览后再调是无害的
                NotificationManager.shared.requestAuthorization()
            }
        }
        .onAppear {
            if !hasSeenOnboarding {
                tour.start()
            }
        }
        .alert(
            String.loc("本地数据库已重建"),
            isPresented: Binding(
                get: { storeRecoveryNotice != nil },
                set: { if !$0 { storeRecoveryNotice = nil; SharedModelContainer.clearRecoveryNotice() } }
            )
        ) {
            Button(String.loc("好的"), role: .cancel) {}
        } message: {
            Text(String.loc("上次启动时本地数据库无法打开，旧文件已原样保留在 App 的 Application Support/StoreBackups 目录中，没有删除。开启了 iCloud 同步的数据会自动恢复；如未开启，请通过反馈联系我们协助找回。"))
        }
        .task {
            do {
                try Point.syncDefaultPoints(in: context)
            } catch {
                print("❌ \(AppError.networkFailure(underlying: error).localizedDescription)")
            }

            // 一次性迁移：旧版通知 identifier 基于 hashValue，重启后无法取消，
            // 这里清理孤儿通知并按稳定 identifier 重新注册
            if !UserDefaults.standard.bool(forKey: AppConfig.UserDefaultsKey.didMigrateReminderIdentifiers) {
                let cards = (try? context.fetch(FetchDescriptor<CreditCard>())) ?? []
                NotificationManager.shared.migrateLegacyReminders(cards: cards)
                UserDefaults.standard.set(true, forKey: AppConfig.UserDefaultsKey.didMigrateReminderIdentifiers)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("主界面 · 五个 Tab") {
    ContentView()
        .previewEnvironment(onboardingSeen: true)
}

#Preview("首启 · 带新手导览") {
    // hasSeenOnboarding = false 时导览蒙层会直接叠在真实界面上，这条专门看那一侧
    ContentView()
        .previewEnvironment(onboardingSeen: false)
}

#Preview("空数据") {
    ContentView()
        .previewEmptyEnvironment()
}
#endif
