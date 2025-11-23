import SwiftUI
import SwiftData
// --- 2. 主入口 (包含底部导航栏) ---
struct ContentView: View {
    // 选中的 Tab 索引
    @State private var selectedTab = 0
    
    var body: some View {
        // TabView 是底部导航栏的核心容器
        TabView(selection: $selectedTab) {
            
            // --- 左边：账单页 ---
            BillHomeView()
                .tabItem {
                    // 只有选中时才变实心图标，更有质感
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
        }
        .tint(.blue) // 设置底部选中时的颜色 (Apple 蓝)
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Transaction.self, CreditCard.self, configurations: config)
    
    SampleData.load(context: container.mainContext)
    
    return ContentView()
        .modelContainer(container)
}
