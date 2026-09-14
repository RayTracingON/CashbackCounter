//
//  CardTemplateListView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import SwiftData

struct CardTemplateListView: View {
    @Environment(\.modelContext) var context
    @Environment(\.dismiss) var dismiss
    @Environment(CardTemplateManager.self) var templateManager

    // 1. 控制跳转的状态：存用户选了哪个模板
    @State private var selectedTemplate: CardTemplate?
    @Binding var rootSheet: SheetType?

    var body: some View {
        NavigationView {
            List(templateManager.templates) { item in
                Button(action: {
                    // 👇 点击后，不直接保存，而是记录选了谁
                    selectedTemplate = item
                }) {
                    HStack {
                        // 👇 核心修改：卡片图标显示逻辑
                        if let urlStr = item.pictureURL {
                            // 👉 分支 A: 如果是网络图片 (http 开头)
                            if urlStr.lowercased().hasPrefix("http"), let url = URL(string: urlStr) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 50, height: 32)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                            .shadow(color: .black.opacity(0.1), radius: 1)
                                        
                                    case .empty:
                                        ProgressView()
                                            .frame(width: 40, height: 40)
                                        
                                    case .failure(_):
                                        gradientCircle(for: item)
                                        
                                    @unknown default:
                                        gradientCircle(for: item)
                                    }
                                }
                            }
                            // 👉 分支 B: 如果是本地 Assets 图片
                            // 使用 UIImage(named:) 检查图片是否存在并直接加载，避免重复查找
                            else if let uiImage = UIImage(named: urlStr) {
                                Image(uiImage: uiImage) // 直接加载 Assets 图片
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 50, height: 32) // 保持相同的尺寸
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .shadow(color: .black.opacity(0.1), radius: 1)
                            }
                            // 👉 分支 C: 既不是 URL 也没在本地找到图片
                            else {
                                gradientCircle(for: item)
                            }
                        } else {
                            // 👉 分支 D: pictureURL 为空
                            gradientCircle(for: item)
                        }
                        

                        VStack(alignment: .leading) {
                            Text(item.bankName).font(.headline)
                            Text(item.type).font(.caption).foregroundColor(.gray)
                        }

                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("选择卡片模板")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            // 👇 2. 核心跳转逻辑
            .sheet(item: $selectedTemplate) { template in
                AddCardView(template: template, onSaved: {
                    // 当添加页保存成功时，执行这行代码：
                    // 把首页的 activeSheet 设为 nil，所有弹窗瞬间全部消失！
                    rootSheet = nil
                })
            }
        }
    }
    
    // MARK: - 辅助视图
    
    // 提取原本的渐变圆圈逻辑，方便复用
    private func gradientCircle(for item: CardTemplate) -> some View {
        Circle()
            .fill(LinearGradient(colors: item.colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 40, height: 40)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("模板卡列表") {
    // 模板来自 PreviewData.templateManager（假数据），不会去打远端 JSON
    @Previewable @State var rootSheet: SheetType? = .template
    CardTemplateListView(rootSheet: $rootSheet)
        .previewEnvironment()
}
#endif
