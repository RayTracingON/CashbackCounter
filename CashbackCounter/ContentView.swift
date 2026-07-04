import SwiftUI
import SwiftData

// --- 2. 主入口 (包含底部导航栏) ---
struct ContentView: View {
    // 选中的 Tab 索引
    @State private var selectedTab = 0
    @Environment(\.modelContext) private var context
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    
    var body: some View {
        // TabView 是底部导航栏的核心容器
        TabView(selection: $selectedTab) {
            
            // --- 左边：账单页 ---
            BillHomeView()
                .tabItem {
                    Image(systemName: selectedTab == 0 ? "doc.text.image.fill" : "doc.text.image")
                    Text("账单")
                }
                .tag(0)
            
            CardListView()
                .tabItem {
                    Image(systemName: selectedTab == 1 ? "creditcard.fill" : "creditcard")
                    Text("卡包")
                }
                .tag(1)
            
            CameraRecordView()
                .tabItem {
                    Image(systemName: "camera.circle.fill") // 大圆圈图标
                    Text("拍一笔")
                }
                .tag(2)
            
            // --- 积分系统页 ---
            PointSystemView()
                .tabItem {
                    Image(systemName: selectedTab == 3 ? "star.circle.fill" : "star.circle")
                    Text("积分")
                }
                .tag(3)
            
            // --- ✨ 新增：设置页 ---
            SettingsView()
                .tabItem {
                    // 选中时变成实心齿轮
                    Image(systemName: selectedTab == 4 ? "gearshape.fill" : "gearshape")
                    Text("设置")
                }
                .tag(4)
        }
        .tint(.blue) // 设置底部选中时的颜色 (Apple 蓝)
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
        .fullScreenCover(
            isPresented: Binding(
                get: { !hasSeenOnboarding },
                set: { newValue in
                    if !newValue {
                        hasSeenOnboarding = true
                    }
                }
            )
        ) {
            OnboardingView {
                hasSeenOnboarding = true
            }
        }
    }
}
