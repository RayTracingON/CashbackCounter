import SwiftUI
import SwiftData

// --- 2. 主入口 (包含底部导航栏) ---
struct ContentView: View {
    // 选中的 Tab 索引
    @State private var selectedTab = 0
    @EnvironmentObject private var aiAvailability: AppleIntelligenceAvailability

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
            
            // --- 中间：拍照/记账页 ---
            CameraRecordView()
                .tabItem {
                    Image(systemName: "camera.circle.fill") // 大圆圈图标
                    Text("拍一笔")
                }
                .tag(1)
            
            // --- 右边：信用卡页 ---
            CardListView()
                .tabItem {
                    Image(systemName: selectedTab == 2 ? "creditcard.fill" : "creditcard")
                    Text("卡包")
                }
                .tag(2)
            
            // --- ✨ 新增：设置页 ---
            SettingsView()
                .tabItem {
                    // 选中时变成实心齿轮
                    Image(systemName: selectedTab == 3 ? "gearshape.fill" : "gearshape")
                    Text("设置")
                }
                .tag(3)
        }
        .tint(.blue) // 设置底部选中时的颜色 (Apple 蓝)
        .task {
            aiAvailability.refreshSupportStatus()
        }
        .alert("兼容模式已启用", isPresented: $aiAvailability.showCompatibilityAlert) {
            Button("好的", role: .cancel) { }
        } message: {
            Text("当前设备暂不支持 Apple Intelligence，已为你切换为手动输入模式。")
        }
        .compatibilityGlass()
    }
}

private extension View {
    @ViewBuilder
    func compatibilityGlass() -> some View {
        if #available(iOS 18.0, *) {
            self.glassBackgroundEffect()
        } else {
            self
        }
    }
}
