//
//  SettingsView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/29/25.
//

import SwiftUI
import SwiftData
import UIKit // 👈 1. 引入 UIKit 以支持 UIActivityViewController

struct SettingsView: View {
    // 获取 App 版本号
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    @AppStorage("userTheme") private var userTheme: Int = 0
    @AppStorage("userLanguage") private var userLanguage: String = "system"
    @AppStorage("mainCurrencyCode") private var mainCurrencyCode: String = "CNY"
    
    @Environment(\.modelContext) var context
    @State private var showConfirmClear: Bool = false
    
    // 👇 2. 新增：获取数据库中的所有卡片和交易 (用于导出)
    @Query var cards: [CreditCard]
    @Query(
        sort: [
            SortDescriptor(\Transaction.date, order: .reverse),
            SortDescriptor(\Transaction.merchant, order: .forward)
        ]
    )
    var transactions: [Transaction]
    
    // 👇 3. 新增：控制导出分享面板的状态
    @State private var showShareSheet = false
    @State private var exportItems: [Any] = []

    
    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.1))
                                .frame(width: 80, height: 80)
                            
                            Image(systemName: "creditcard.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.blue)
                                .offset(x: -5, y: 0)
                            
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 24))
                                .foregroundColor(.green)
                                .padding(4)
                                .background(Color(uiColor: .systemGroupedBackground).clipShape(Circle()))
                                .offset(x: 18, y: 12)
                        }
                        .padding(.bottom, 4)
                        
                        Text("Cashback Counter")
                            .font(.headline)
                            .fontWeight(.bold)
                        
                        Text("Version \(appVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .listRowBackground(Color.clear)
                
                Section(header: Text("外观与语言")) {
                    Picker(selection: $userTheme, label: Label("主题模式", systemImage: "paintpalette")) {
                        Text("跟随系统").tag(0)
                        Text("浅色模式").tag(1)
                        Text("深色模式").tag(2)
                    }
                    
                    Picker(selection: $userLanguage, label: Label("语言设置", systemImage: "globe")) {
                        Text("跟随系统").tag("system")
                        Text("简体中文").tag("zh-Hans")
                        Text("繁體中文").tag("zh-Hant")
                        Text("English").tag("en")
                    }
                }
                
                Section(header: Text("常规")) {
                    Picker(selection: $mainCurrencyCode, label: Label("主货币", systemImage: "banknote")) {
                        Text("人民币 (CNY)").tag("CNY")
                        Text("美元 (USD)").tag("USD")
                        Text("港币 (HKD)").tag("HKD")
                        Text("日元 (JPY)").tag("JPY")
                    }
                    
                    NavigationLink(destination: NotificationSettingsView()) {
                        Label("通知提醒", systemImage: "bell")
                    }
                }
                
                Section(header: Text("数据管理")) {
                    Label("iCloud 同步 (功能正在开发中)", systemImage: "icloud")
                        .foregroundColor(.secondary)
                    
                    // 👇 4. 修改：将原本的文字提示改为导出按钮
                    Button {
                        exportAllData()
                    } label: {
                        HStack {
                            Label("全部数据导出", systemImage: "square.and.arrow.up")
                            Spacer()
                            // 提示用户点击后会发生什么
                            Text("导出卡片与账单")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    // 绑定分享面板
                    .sheet(isPresented: $showShareSheet) {
                        ActivityViewController(activityItems: exportItems)
                            .presentationDetents([.medium, .large])
                    }
                }
                
                Section(header: Text("关于 Cashback Counter")) {
                    HStack {
                        Label("版本", systemImage: "info.circle")
                        Spacer()
                        Text("v\(appVersion)")
                            .foregroundColor(.secondary)
                    }
                    
                    NavigationLink(destination: DeveloperView()) {
                        Label("开发者/贡献者", systemImage: "person.crop.circle")
                    }
                }
                
                Section {
                    Button(role: .destructive) {
                        showConfirmClear = true
                    } label: {
                        Label("重置所有数据 (慎用)", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                    .confirmationDialog(
                        "确定要清除所有数据吗？",
                        isPresented: $showConfirmClear,
                        titleVisibility: .visible
                    ) {
                        Button("清除", role: .destructive) {
                            clearAllData()
                        }
                        Button("取消", role: .cancel) {}
                    }
                }
            }
            .navigationTitle("设置")
            .listStyle(.insetGrouped)
        }
    }
    
    // 👇 5. 新增：执行导出的逻辑
    private func exportAllData() {
        var items: [Any] = []
        
        // A. 导出卡片 CSV
        if let cardCSV = cards.exportCSVFile() {
            items.append(cardCSV)
        }
        
        // B. 导出账单+收据 ZIP (使用你之前写好的新方法)
        if let backupZip = transactions.exportReceiptsZip() {
            items.append(backupZip)
        }
        
        // C. 显示分享面板
        if !items.isEmpty {
            self.exportItems = items
            self.showShareSheet = true
        }
    }
    
    private func clearAllData() {
        do {
            try deleteAll(of: Transaction.self)
            try deleteAll(of: CreditCard.self)
            try context.save()
            print("✅ All data cleared")
        } catch {
            print("❌ Failed to clear data: \(error)")
        }
    }

    private func deleteAll<T>(of type: T.Type) throws where T: SwiftData.PersistentModel {
        let descriptor = SwiftData.FetchDescriptor<T>()
        let items = try context.fetch(descriptor)
        for item in items {
            context.delete(item)
        }
    }
}

// 👇 6. 新增：UIActivityViewController 的 SwiftUI 封装
struct ActivityViewController: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
