//
//  SettingsView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/29/25.
//

import SwiftUI

struct SettingsView: View {
    // 获取 App 版本号
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    // 1. 外观设置 (0=跟随, 1=浅色, 2=深色)
    @AppStorage("userTheme") private var userTheme: Int = 0
        
    // 2. 语言设置 "system" = 跟随系统, "zh-Hans" = 中文, "en" = 英文
    @AppStorage("userLanguage") private var userLanguage: String = "system"
    var body: some View {
        NavigationView {
            List {
            // 👇👇👇 1. 新增：顶部的 App 图标 Header 👇👇👇
                Section {
                    VStack(spacing: 8) {
                        // 图标组合
                        ZStack {
                            // 背景装饰 (可选，增加层次感)
                            Circle()
                                .fill(Color.blue.opacity(0.1))
                                .frame(width: 80, height: 80)
                            
                            // 1. 卡片
                            Image(systemName: "creditcard.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.blue)
                                .offset(x: -5, y: 0) // 稍微往左偏一点
                            
                            // 2. 循环圈 (叠加在右下角)
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 24))
                                .foregroundColor(.green)
                                .padding(4)
                            // 加个白色底色，防止和卡片重叠部分看不清
                                .background(Color(uiColor: .systemGroupedBackground).clipShape(Circle()))
                                .offset(x: 18, y: 12)
                        }
                        .padding(.bottom, 4)
                        
                        // App 名称
                        Text("Cashback Counter")
                            .font(.headline)
                            .fontWeight(.bold)
                        
                        // 版本号
                        Text("Version \(appVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity) // 让它水平居中
                    .padding(.vertical, 10)
                }
                    .listRowBackground(Color.clear)
                Section(header: Text("外观与语言")) {
                    // 主题选择
                    Picker(selection: $userTheme, label: Label("主题模式", systemImage: "paintpalette")) {
                        Text("跟随系统").tag(0)
                        Text("浅色模式").tag(1)
                        Text("深色模式").tag(2)
                    }
                    
                    // ✨ 语言选择
                    Picker(selection: $userLanguage, label: Label("语言设置", systemImage: "globe")) {
                        Text("跟随系统").tag("system")
                        Text("简体中文").tag("zh-Hans")
                        Text("English").tag("en")
                    }
                }
                // 1. 常规设置 (预留位置)
                Section(header: Text("常规")) {
                    NavigationLink(destination: Text("更多货币支持正在开发中...")) {
                        Label("多币种设置", systemImage: "banknote")
                    }
                    
                    NavigationLink(destination: NotificationSettingsView()) {
                        Label("通知提醒", systemImage: "bell")
                    }
                }
                
                // 2. 数据管理 (你可以考虑把导入导出逻辑迁移到这里)
                Section(header: Text("数据管理")) {
                    Label("iCloud 同步 (自动开启)", systemImage: "icloud")
                        .foregroundColor(.secondary)
                    
                    // 这是一个提示，告诉用户去哪里导出
                    HStack {
                        Label("数据导入/导出", systemImage: "square.and.arrow.up")
                        Spacer()
                        Text("见首页右上角")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                
                // 3. 关于
                Section(header: Text("关于 Cashback Counter")) {
                    HStack {
                        Label("版本", systemImage: "info.circle")
                        Spacer()
                        Text("v\(appVersion)")
                            .foregroundColor(.secondary)
                    }
                    
                    Label("开发者: Junhao Huang", systemImage: "person.crop.circle")
                    
                    // 如果有 GitHub 地址可以放这里
                    Link(destination: URL(string: "https://github.com/raytracingon/cashbackcounter")!) {
                        Label("项目主页", systemImage: "link")
                    }
                }
                
                // 4. 其它
                Section {
                    Button(role: .destructive) {
                        // 这里可以放清空数据的逻辑
                    } label: {
                        Label("重置所有数据 (慎用)", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("设置")
            .listStyle(.insetGrouped) // 使用 iOS 风格的分组列表
        }
    }
}

#Preview {
    SettingsView()
}
