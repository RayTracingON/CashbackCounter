//
//  CardListView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers
// 定义弹窗类型
enum SheetType: Identifiable {
    case template
    case custom
    var id: Int { hashValue }
}


struct CardListView: View {
    @Query var cards: [CreditCard]
    @Environment(\.modelContext) var context
    
    // 控制编辑状态
    @State private var cardToEdit: CreditCard?
    // 控制添加状态
    @State private var activeSheet: SheetType?
    // 导入导出卡
    @State private var showFileExporter = false
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var showImportAlert = false
    // 核心状态：当前展开的卡片 ID
    @State private var selectedCardID: PersistentIdentifier? = nil
    @State private var scrollOffset: CGFloat = 0
    // 👇 新增：计算属性，全视图通用
    private var isDetailMode: Bool {
        selectedCardID != nil
    }
    var cardfli: [Transaction] {
        guard let selectedCard = cards.first(where: { $0.id == selectedCardID }) else {
            return []
        }
        return (selectedCard.transactions ?? []).sorted { $0.date > $1.date }
    }

    // 动画参数
    private let springAnimation = Animation.spring(response: 0.5, dampingFraction: 0.75, blendDuration: 0)
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                // 背景色
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                
                // --- 图层 1: 交易详情列表 (在最底层) ---
                if let selectedID = selectedCardID,
                   let selectedCard = cards.first(where: { $0.id == selectedID }) {
                    
                    ScrollView(showsIndicators: false) {
                        EmbeddedTransactionListView(card: selectedCard)
                    }
                    .padding(.top, 220)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(0)
                }
                
                // --- 图层 2: 卡片列表 (在顶层) ---
                ScrollView(showsIndicators: false) {
                    ZStack(alignment: .top) {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ScrollOffsetKey.self,
                                // 计算当前 ScrollView 内容相对于 "scrollSpace" 的偏移
                                value: -proxy.frame(in: .named("scrollSpace")).minY
                            )
                        }
                        .frame(height: 0) // 不占用空间
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            
                            // 计算当前卡片的状态
                            let isSelected = card.id == selectedCardID
                            // 👇 这里不再需要定义 let isDetailMode = ...
                            
                            CreditCardView(
                                bankName: card.bankName,
                                type: card.type,
                                endNum: card.endNum,
                                colors: card.colors
                            )
                            .contentShape(Rectangle())
                            // 控制位置和动画
                            .offset(y: isSelected
                                    // 选中时：停在当前滚动位置 + 顶部留白
                                    ? (scrollOffset + 10)
                                    // 未选中时：正常列表逻辑
                                    : (isDetailMode ? 800 : CGFloat(index * 100 + 20))
                            )                            // 控制透明度和缩放
                            .opacity(isDetailMode && !isSelected ? 0 : 1)
                            .scaleEffect(isDetailMode && !isSelected ? 0.9 : 1)
                            // 控制层级
                            .zIndex(isSelected ? 100 : Double(index))
                            .shadow(color: .black.opacity(isDetailMode ? 0.2 : 0.1), radius: isDetailMode ? 20 : 10, x: 0, y: 5)
                            // 点击手势
                            .onTapGesture {
                                withAnimation(springAnimation) {
                                    if isSelected {
                                        selectedCardID = nil
                                        
                                    } else {
                                        selectedCardID = card.id
                                    }
                                }
                            }
                            
                        }
                    }
                    // 👇 这里的报错应该消失了
                    Color.clear
                        .frame(height: CGFloat(max(1, cards.count) * 100 + 20 ))
                }
                .coordinateSpace(name: "scrollSpace")
                // 🔥 核心修改 6: 监听滚动位置变化
                .onPreferenceChange(ScrollOffsetKey.self) { value in
                    // 只有在没展开卡片的时候更新位置，展开后锁定这个值，防止卡片跟着详情页的滚动乱跑
                    if !isDetailMode {
                        scrollOffset = value
                    }
                }
                // 👇 这里的报错也应该消失了
                .scrollDisabled(isDetailMode)
                .allowsHitTesting(!isDetailMode)
                .zIndex(1)
                if isDetailMode {
                    Color.clear // 透明色
                        .contentShape(Rectangle()) // 只有定义了形状才能响应点击
                        .frame(height: 220) // 高度与卡片一致
                        .padding(.horizontal, 16) // 稍微加点左右边距(如果你的卡片有缩进的话)
                        .padding(.top, 10) // 🔥 重要：必须和卡片的 offset 顶部距离一致
                        .zIndex(2) // 放在最顶层
                        .onTapGesture {
                            // 点击这里触发关闭动画
                            withAnimation(springAnimation) {
                                selectedCardID = nil
                            }
                        }
                }
            }
            // ... (导航栏和 Toolbar 代码保持不变) ...
            .navigationTitle(
                selectedCardID != nil
                ? (cards.first(where: {$0.id == selectedCardID})?.bankName ?? "")
                : "我的卡包"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // 判断当前是否有选中的卡片
                    if let selectedID = selectedCardID,
                       let selectedCard = cards.first(where: { $0.id == selectedID }) {
                        // ✨ 新增：三点菜单
                        Menu {
                            // 选项 1: 编辑
                            Button {
                                cardToEdit = selectedCard
                            } label: {
                                Label("编辑卡片", systemImage: "pencil")
                            }
                            
                            // 选项 2: 导出 (这里先预留位置)
                            
                            
                            if let csvURL = cardfli.exportCSVFile() {
                                ShareLink(item: csvURL) {
                                    Label("导出交易", systemImage: "square.and.arrow.up")
                                }
                            }
                            
                            
                            Divider() // 分割线，把危险操作隔开
                            
                            // 选项 3: 删除
                            Button(role: .destructive) {
                                withAnimation(springAnimation) {
                                    // 1. 先关闭详情页
                                    selectedCardID = nil
                                    // 2. 稍微延迟一点再删除，视觉体验更好，也可以直接删
                                    // 这里直接删除:
                                    context.delete(selectedCard)
                                }
                            } label: {
                                Label("删除卡片", systemImage: "trash")
                            }
                            
                        } label: {
                            // 按钮图标：实心圆圈三点
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.system(size: 24))
                            // 稍微把颜色加深一点，让它看起来更像可交互按钮
                        }
                    }else {
                        Menu {
                            Button(action: { activeSheet = .template }) { Label("从模板添加", systemImage: "doc.on.doc") }
                            
                            Button(action: { activeSheet = .custom }) { Label("自定义添加", systemImage: "square.and.pencil") }
                            
                            Divider()
                            
                            if let csvURL = cards.exportCSVFile() {
                                ShareLink(item: csvURL) {
                                    Label("导出卡片", systemImage: "square.and.arrow.up")
                                }
                            }
                            
                            Button {
                                showFileImporter = true
                            } label: {
                                Label("导入卡片", systemImage: "square.and.arrow.down")
                            }
                        }
                        label: {
                            Image(systemName: "ellipsis.circle.fill").font(.system(size: 24))
                        }
                    }
                }
            }
            .sheet(item: $activeSheet) { type in
                switch type {
                case .template: CardTemplateListView(rootSheet: $activeSheet)
                case .custom: AddCardView()
                }
            }
            .sheet(item: $cardToEdit) { card in
                AddCardView(cardToEdit: card)
            }

            // 👇 处理导入
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.commaSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    // 必须处理安全访问权限
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    
                    do {
                        let content = try String(contentsOf: url, encoding: .utf8)
                        try CardCSVHelper.parseCSV(content: content, into: context)
                        importError = nil // 成功
                    } catch {
                        importError = "导入失败：格式错误或文件损坏。\n\(error.localizedDescription)"
                        showImportAlert = true
                    }
                case .failure(let error):
                    print("选择文件失败: \(error.localizedDescription)")
                }
            }
            // 导入失败的提示框
            .alert("导入结果", isPresented: $showImportAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(importError ?? "未知错误")
            }
        
        }
    }

}



struct EmbeddedTransactionListView: View {
    let card: CreditCard
    @State private var selectedTransaction: Transaction? = nil
    @State private var transactionToEdit: Transaction?
    @Environment(\.modelContext) var context

    // 按日期倒序排列交易
    var sortedTransactions: [Transaction] {
        (card.transactions ?? []).sorted { $0.date > $1.date }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            
            // 列表标题
            Text("最新交易")
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.leading, 16)
                .padding(.top, 10)
            
            if sortedTransactions.isEmpty {
                // 空状态
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundColor(.gray.opacity(0.4))
                    Text("此卡片暂无交易记录")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                
            } else {
                // 交易列表容器
                LazyVStack(spacing: 15) {
                    ForEach(sortedTransactions) { item in
                        TransactionRow(transaction: item)
                            .onTapGesture { selectedTransaction = item }
                            .contextMenu {
                                Button { transactionToEdit = item } label: { Label("编辑", systemImage: "pencil") }
                                Button(role: .destructive) { context.delete(item) } label: { Label("删除", systemImage: "trash") }
                            }
                    }
                }
                .padding(.horizontal)
                .sheet(item: $selectedTransaction) { item in
                    TransactionDetailView(transaction: item).presentationDetents([.large])
                }
                .sheet(item: $transactionToEdit) { item in
                    AddTransactionView(transaction: item)
                }
            }
            
            // 底部垫高，防止被 TabBar 遮挡
            Spacer().frame(height: 50)
        }
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
