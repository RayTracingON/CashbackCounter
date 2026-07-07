//
//  SettingsView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/29/25.
//

import SwiftUI
import SwiftData
import UIKit

// MARK: - Helper Models
// 1. 新增：用于封装分享数据的结构体，遵循 Identifiable 协议
// 这解决了 .sheet(isPresented:) 导致的时序问题
struct ShareData: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct SettingsView: View {
    // MARK: - Properties
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    
    @AppStorage("userTheme") private var userTheme: Int = 0
    @AppStorage("userLanguage") private var userLanguage: String = "system"
    @AppStorage("mainCurrencyCode") private var mainCurrencyCode: String = "CNY"
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @AppStorage("defaultCardID") private var defaultCardID: String = ""
    // key 与 ReceiptParser.cloudModelDefaultsKey 保持一致
    @AppStorage("useCloudAIModel") private var useCloudAIModel: Bool = false
    @State private var showSyncChangeAlert = false
    
    @Environment(\.modelContext) var context
    
    // 获取数据库数据
    @Query var cards: [CreditCard]
    @Query(
        sort: [
            SortDescriptor(\Transaction.date, order: .reverse),
            SortDescriptor(\Transaction.merchant, order: .forward)
        ]
    )
    var transactions: [Transaction]
    
    // ViewModel
    @State private var viewModel = SettingsViewModel()

    // MARK: - Body
    var body: some View {
        NavigationView {
            List {
                // Header Section
                Section {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.1))
                            .frame(width: DesignConstants.Size.settingsIconCircle, height: DesignConstants.Size.settingsIconCircle)
                            
                            Image(systemName: "creditcard.fill")
                                .font(.system(size: DesignConstants.Size.settingsIconFont))
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
                
                // Appearance Section
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
                
                // General Section
                Section(header: Text("常规")) {
                    Picker(selection: $mainCurrencyCode, label: Label("主货币", systemImage: "banknote")) {
                        Text("人民币 (CNY)").tag("CNY")
                        Text("美元 (USD)").tag("USD")
                        Text("港币 (HKD)").tag("HKD")
                        Text("日元 (JPY)").tag("JPY")
                        Text("澳门币（MOP)").tag("MOP")
                        Text("欧元（EUR）").tag("EUR")
                        Text("英镑（GBP）").tag("GBP")
                        Text("新台币（TWD）").tag("TWD")
                    }
                    
                    Picker(selection: $defaultCardID, label: Label("默认记账卡片", systemImage: "creditcard.circle")) {
                        Text("无默认卡片").tag("")
                        ForEach(cards) { card in
                            Text("\(card.bankName) (\(card.endNum))").tag("\(card.bankName)|\(card.endNum)")
                        }
                    }
                    
                    NavigationLink(destination: NotificationSettingsView()) {
                        Label("通知提醒", systemImage: "bell")
                    }
                }

                // AI Model Section
                Section {
                    if #available(iOS 27.0, *) {
                        Toggle(isOn: $useCloudAIModel) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("使用云端模型")
                                    Text("识别能力更强，需要网络连接")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } icon: {
                                Image(systemName: "cloud.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    } else {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("本地模型")
                                Text("云端模型需要升级到 iOS 27")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "iphone")
                                .foregroundColor(.gray)
                        }
                    }
                } header: {
                    Text("AI 智能识别")
                } footer: {
                    Text("云端解析通过 Apple Private Cloud Compute 完成：数据端到端加密，Apple 与开发者均无法读取。云端不可用时会自动回退到本地模型。")
                }

                // Shortcuts Section
                Section(header: Text("自动化与快捷指令")) {
                    Link(destination: URL(string: "https://www.icloud.com/shortcuts/aceb7bb680d74a99aaee23f2c9005089")!) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("获取截屏记账快捷指令")
                                    .foregroundColor(.primary)
                                Text("配合操作按钮，一键截屏并自动入账")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "camera.viewfinder")
                                .foregroundColor(.blue)
                        }
                    }
                    
                    NavigationLink(destination: ShortcutGuideView()) {
                        Label("自动化配置教程", systemImage: "book.pages")
                    }
                }
                
                // Data Management Section
                Section(header: Text("数据管理")) {
                    Toggle(isOn: $iCloudSyncEnabled) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iCloud 数据同步")
                                Text("在登录相同 Apple ID 的设备间自动同步")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "icloud.fill")
                                .foregroundColor(.blue)
                        }
                    }
                    .onChange(of: iCloudSyncEnabled) { _, _ in
                        showSyncChangeAlert = true
                    }

                    Button {
                        viewModel.startExportProcess(cards: cards, transactions: transactions)
                    } label: {
                        HStack {
                            Label("全部数据导出", systemImage: "square.and.arrow.up")
                            Spacer()
                            
                            if viewModel.isExporting {
                                ProgressView()
                                    .padding(.leading, 5)
                            } else {
                                Text("导出卡片与账单")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .disabled(viewModel.isExporting) // 导出过程中禁止重复点击

                    NavigationLink(destination: PrivacyPolicyView()) {
                        Label("隐私政策", systemImage: "hand.raised")
                    }
                }
                
                // About Section
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

                Section(header: Text("更新说明")) {
                    NavigationLink(destination: UpdateNotesView(appVersion: appVersion)) {
                        Label("更新版本注意事项", systemImage: "exclamationmark.triangle")
                    }
                }
                
                // Reset Section
                Section {
                    Button(role: .destructive) {
                        viewModel.showConfirmClear = true
                    } label: {
                        Label("重置所有数据 (慎用)", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                    .confirmationDialog(
                        "确定要清除所有数据吗？",
                        isPresented: $viewModel.showConfirmClear,
                        titleVisibility: .visible
                    ) {
                        Button("清除", role: .destructive) {
                            viewModel.clearAllData(context: context)
                        }
                        Button("取消", role: .cancel) {}
                    }
                }
            }
            .navigationTitle("设置")
            .listStyle(.insetGrouped)
            // 4. 关键修复：使用 item: $shareData 绑定
            // 只有当 shareData 有值时，才会初始化并显示 ActivityViewController
            .sheet(item: $viewModel.shareData) { data in
                ActivityViewController(activityItems: data.items)
                    .presentationDetents([.medium, .large])
            }
            .alert("同步设置已更改", isPresented: $showSyncChangeAlert) {
                Button("好的", role: .cancel) { }
            } message: {
                Text("iCloud 数据同步设置已更改。请完全退出应用并重新启动，以使新的同步配置生效。")
            }
        }
    }
}

private struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("隐私政策")
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 4)

                Text("我们重视你的隐私。以下为应用当前版本的隐私说明：")
                    .foregroundColor(.secondary)

                Text("• 数据存储：账单、卡片、积分等数据全部保存在你的设备本地，我们不上传任何个人数据。")
                Text("• 网络请求：应用可能会为获取汇率、下载卡面等功能访问网络，仅下载必要参数。")
                Text("• 权限使用：相机、相册、通知等权限仅在对应功能使用时申请，可在系统设置中随时关闭。")
                Text("• 分享导出：仅当你主动使用导出功能时，数据才会通过系统导出面板离开应用。")

                Text("若你对隐私相关内容有疑问，请联系开发者。")
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("隐私政策")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct UpdateNotesView: View {
    let appVersion: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("更新版本注意事项")
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 4)

                Text("当前版本：v\(appVersion)")
                    .foregroundColor(.secondary)

                Text("• 更新前建议使用全部数据导出进行备份！！！（重要）。")
                Text("• 更新后首次打开可能需要短暂时间完成数据整理。")
                Text("• 若更新后出现应用闪退或异常的情况请删除应用，重新下载并导入之前备份的数据")
                Text("• 若问题仍存在，请联系开发者协助排查。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("更新注意事项")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - ActivityViewController
struct ActivityViewController: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ShortcutGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - 截屏记账
                VStack(alignment: .leading, spacing: 12) {
                    Label("操作按钮一键截屏记账", systemImage: "camera.viewfinder")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.blue)
                    
                    Text("通过搭配 iPhone 的操作按钮 (Action Button)，你可以实现在任何页面一键截屏并自动记账。")
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. 获取快捷指令")
                            .font(.headline)
                        
                        Link(destination: URL(string: "https://www.icloud.com/shortcuts/aceb7bb680d74a99aaee23f2c9005089")!) {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                Text("下载截屏记账快捷指令")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("2. 配置与使用")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• 打开 iPhone「设置」>「操作按钮」")
                            Text("• 滑动选择「快捷指令」，选取刚下载的快捷指令")
                            Text("• 在任何消费凭证页面，长按操作按钮即可自动截屏记账")
                        }
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)
                
                // MARK: - 短信记账
                VStack(alignment: .leading, spacing: 12) {
                    Label("信用卡短信自动记账", systemImage: "text.bubble")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.green)
                    
                    Text("通过快捷指令的「自动化」功能，在收到银行扣款短信时可以自动后台记账，无需手动操作。")
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("配置步骤")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. 打开「快捷指令」App，切换到「自动化」标签")
                            Text("2. 点击右上角「+」新建自动化，选择「信息」")
                            Text("3. 在「发件人」处填入银行短信号码（如 95588）")
                            Text("4. 勾选「立即运行」，点击「下一步」")
                            Text("5. 添加操作：搜索 Cashback Counter，选择「解析信用卡短信」")
                            Text("6. 点击操作卡片中的「短信全文」变量，选择上方的「快捷指令输入」>「信息」")
                            Text("7. 点击「完成」保存自动化")
                        }
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)
            }
            .padding()
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("自动化与快捷指令教程")
        .navigationBarTitleDisplayMode(.inline)
    }
}
