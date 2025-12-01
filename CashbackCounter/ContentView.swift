import SwiftUI
import SwiftData
import UIKit

// --- 2. 主入口 (包含底部导航栏) ---
struct ContentView: View {
    // 选中的 Tab 索引
    @State private var selectedTab = 0
    @State private var showIntentAddSheet = false
    @State private var pendingReceiptImage: UIImage?
    
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
        .onAppear {
            handlePendingReceipt()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
            handlePendingReceipt()
        }
        .sheet(isPresented: $showIntentAddSheet) {
            AddTransactionView(image: pendingReceiptImage) {
                // 关闭后刷新账单列表即可
            }
            .onDisappear {
                pendingReceiptImage = nil
            }
        }
    }

    /// 检查是否有来自 AppIntent 的待处理收据，如果有则跳转到记账页。
    private func handlePendingReceipt() {
        if let image = ReceiptLaunchStore.shared.consumePendingReceipt() {
            pendingReceiptImage = image
            selectedTab = 1
            showIntentAddSheet = true
        }
    }
}
