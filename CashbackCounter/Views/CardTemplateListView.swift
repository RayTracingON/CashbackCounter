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
    /// 当前筛选的银行，nil 表示不筛选
    @State private var selectedBank: String?
    @Binding var rootSheet: SheetType?

    var body: some View {
        NavigationView {
            List(filteredTemplates) { item in
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
            .animation(.default, value: selectedBank)
            .overlay {
                // 模板还没拉下来时不算"筛空了"，那种情况应该让列表保持空白等数据
                if filteredTemplates.isEmpty && !templateManager.templates.isEmpty {
                    emptyFilterResult
                }
            }
            .navigationTitle("选择卡片模板")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    bankFilterMenu
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

    // MARK: - 筛选

    /// 当前要展示的模板。
    ///
    /// 选中的银行在列表里不存在时（远端 JSON 刷新后这家银行没了）自动退回全部，
    /// 而不是把一个空列表甩给用户。这里是 body 求值路径，不能改 @State，
    /// 所以只能"读的时候兜底"而不是去重置 selectedBank。
    private var filteredTemplates: [CardTemplate] {
        guard let selectedBank,
              availableBanks.contains(where: { $0.name == selectedBank }) else {
            return templateManager.templates
        }
        return templateManager.templates.filter { $0.bankName == selectedBank }
    }

    /// 有模板的银行及其模板数。
    ///
    /// 顺序直接沿用 templateManager 排好的顺序（按银行名升序），不再排一次。
    private var availableBanks: [(name: String, count: Int, region: Region)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var regionTally: [String: [Region: Int]] = [:]

        for template in templateManager.templates {
            if counts[template.bankName] == nil { order.append(template.bankName) }
            counts[template.bankName, default: 0] += 1
            regionTally[template.bankName, default: [:]][template.region, default: 0] += 1
        }

        return order.map { name in
            // 同一家银行在多个地区发卡时（少见），归到模板最多的那个地区。
            // 平票时按地区名排序取第一个，保证每次渲染的分组结果一样。
            let region = (regionTally[name] ?? [:])
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
                .first?.key ?? .other
            return (name, counts[name] ?? 0, region)
        }
    }

    /// 按发卡地区分组后的银行，菜单里用 Section 分隔。
    /// 十几家银行平铺成一列很难扫，按地区分开之后用户基本只看自己那一段。
    private var bankGroups: [(region: Region, banks: [(name: String, count: Int, region: Region)])] {
        let grouped = Dictionary(grouping: availableBanks, by: \.region)
        return Region.allCases.compactMap { region in
            guard let banks = grouped[region], !banks.isEmpty else { return nil }
            return (region, banks)
        }
    }

    // MARK: - 辅助视图

    private var bankFilterMenu: some View {
        Menu {
            menuRow(title: Text("全部银行 (\(templateManager.templates.count))"),
                    isSelected: selectedBank == nil) {
                selectedBank = nil
            }

            ForEach(bankGroups, id: \.region) { group in
                // 地区名用 verbatim：icon 和 rawValue 都是现成的字符串，
                // 拼进 LocalizedStringKey 只会往目录里塞一条没意义的 "%@ %@"
                Section {
                    ForEach(group.banks, id: \.name) { bank in
                        // 银行名是专有名词，不进本地化目录，所以用 verbatim
                        menuRow(title: Text(verbatim: "\(bank.name) (\(bank.count))"),
                                isSelected: selectedBank == bank.name) {
                            selectedBank = bank.name
                        }
                    }
                } header: {
                    Text(verbatim: "\(group.region.icon) \(group.region.rawValue)")
                }
            }
        } label: {
            Image(systemName: selectedBank == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("按银行筛选")
    }

    /// 菜单里的一行。勾选态必须靠 `Label` 带一个 checkmark 图标来表达 ——
    /// 自己画 Image 会被菜单当成普通图标塞到左边，样式对不上系统。
    private func menuRow(title: Text, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label { title } icon: { Image(systemName: "checkmark") }
            } else {
                title
            }
        }
    }

    private var emptyFilterResult: some View {
        ContentUnavailableView {
            Label("没有该银行的卡模板", systemImage: "creditcard.trianglebadge.exclamationmark")
        } actions: {
            Button("显示全部") { selectedBank = nil }
        }
    }

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
