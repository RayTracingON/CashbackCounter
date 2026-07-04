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
    @Query(sort: [SortDescriptor(\CreditCard.bankName, order: .forward)])
    var cards: [CreditCard]
    @Environment(\.modelContext) var context
    
    // ViewModel
    @State private var viewModel = CardListViewModel()

    // 动画参数
    private let springAnimation = Animation.spring(response: 0.5, dampingFraction: 0.75, blendDuration: 0)
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                // 背景色
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                
                // --- 图层 1: 交易详情列表 (在最底层) ---
                if let selectedID = viewModel.selectedCardID,
                   let selectedCard = cards.first(where: { $0.id == selectedID }) {
                    
                    ScrollView(showsIndicators: false) {
                        EmbeddedTransactionListView(card: selectedCard)
                    }
                    .padding(.top, DesignConstants.CardList.transactionListTopPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(0)
                }
                
                // --- 图层 2: 卡片列表 (在顶层) ---
                ScrollView(showsIndicators: false) {
                    ZStack(alignment: .top) {
                        // ❌ 已删除：旧的 GeometryReader 和 ScrollOffsetKey 逻辑
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            
                            // 计算当前卡片的状态
                            let isSelected = card.id == viewModel.selectedCardID
                            
                            CreditCardView(
                                bankName: card.bankName,
                                type: card.type,
                                endNum: card.endNum,
                                colors: card.colors,
                                cardImageData: card.cardImageData
                            )
                            .contentShape(Rectangle())
                            // 控制位置和动画
                            .offset(y: isSelected
                                    // 选中时：停在当前滚动位置 + 顶部留白
                                    ? (viewModel.scrollOffset + DesignConstants.CardList.selectedTopInset)
                                    // 未选中时：正常列表逻辑
                                    : (viewModel.isDetailMode ? DesignConstants.CardList.detailPushDistance : CGFloat(index) * DesignConstants.CardList.stackOffset + DesignConstants.CardList.listTopPadding)
                            )
                            // 控制透明度和缩放
                            .opacity(viewModel.isDetailMode && !isSelected ? 0 : 1)
                            .scaleEffect(viewModel.isDetailMode && !isSelected ? 0.9 : 1)
                            // 控制层级
                            .zIndex(isSelected ? 100 : Double(index))
                            .shadow(color: .black.opacity(viewModel.isDetailMode ? 0.2 : 0.1), radius: viewModel.isDetailMode ? 20 : 10, x: 0, y: 5)
                            // 点击手势
                            .onTapGesture {
                                withAnimation(springAnimation) {
                                    viewModel.toggleCardSelection(card)
                                }
                            }
                        }
                        
                        // 底部占位，保证最后一张卡片能显示完整
                        Color.clear
                            .frame(height: CGFloat(max(1, cards.count)) * DesignConstants.CardList.placeholderPerCard + DesignConstants.CardList.listTopPadding )
                    }
                }
                // ✅ 新增：iOS 18 原生滚动监听
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    // 提取 Y 轴偏移量
                    geometry.contentOffset.y
                } action: { oldValue, newValue in
                    // 只有在没展开卡片的时候更新位置，展开后锁定这个值
                    if !viewModel.isDetailMode {
                        viewModel.scrollOffset = newValue
                    }
                }
                .scrollDisabled(viewModel.isDetailMode)
                .allowsHitTesting(!viewModel.isDetailMode)
                .zIndex(1)
                
                // --- 点击关闭层 ---
                if viewModel.isDetailMode {
                    Color.clear // 透明色
                        .contentShape(Rectangle()) // 只有定义了形状才能响应点击
                        .frame(height: DesignConstants.CardList.closeOverlayHeight) // 高度与卡片一致
                        .padding(.horizontal, 16)
                        .padding(.top, 10) // 🔥 重要：必须和卡片的 offset 顶部距离一致
                        .zIndex(2) // 放在最顶层
                        .onTapGesture {
                            // 点击这里触发关闭动画
                            withAnimation(springAnimation) {
                                viewModel.selectedCardID = nil
                            }
                        }
                }
            }
            // ... (导航栏和 Toolbar 代码) ...
            .navigationTitle(
                viewModel.selectedCardID != nil
                ? (cards.first(where: {$0.id == viewModel.selectedCardID})?.bankName ?? "")
                : "我的卡包"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // 判断当前是否有选中的卡片
                    if let selectedID = viewModel.selectedCardID,
                       let selectedCard = cards.first(where: { $0.id == selectedID }) {
                        // ✨ 菜单：选中状态
                        Menu {
                            Button {
                                viewModel.cardToEdit = selectedCard
                            } label: {
                                Label("编辑卡片", systemImage: "pencil")
                            }
                            
                            let cardfli = viewModel.selectedCardTransactions(from: cards)
                            if !cardfli.isEmpty,
                               let receiptsZipURL = cardfli.exportReceiptsZip() {
                                    ShareLink(items: [receiptsZipURL]) {
                                        Label("导出交易", systemImage: "square.and.arrow.up")
                                    }
                            }
                            
                            Divider()
                            
                            Button(role: .destructive) {
                                withAnimation(springAnimation) {
                                    viewModel.deleteSelectedCard(from: cards, context: context)
                                }
                            } label: {
                                Label("删除卡片", systemImage: "trash")
                            }
                            
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.system(size: 24))
                        }
                    } else {
                        // ✨ 菜单：默认状态
                        Menu {
                            Button(action: { viewModel.activeSheet = .template }) { Label("从模板添加", systemImage: "doc.on.doc") }
                            
                            Button(action: { viewModel.activeSheet = .custom }) { Label("自定义添加", systemImage: "square.and.pencil") }
                            
                            Divider()
                            
                            
                            if !cards.isEmpty,
                               let csvURL = cards.exportCSVFile() {
                                ShareLink(item: csvURL) {
                                    Label("导出卡片", systemImage: "square.and.arrow.up")
                                }
                            }
                            
                            Button {
                                viewModel.showFileImporter = true
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
            .onAppear {
                Task { @MainActor in
                    await CardTemplateManager.shared.syncTemplates()
                    do {
                        try CardTemplateManager.shared.refreshCardsFromTemplates(in: context)
                    } catch {
                        print("Failed to sync card templates: \(error)")
                    }
                }
            }
            .sheet(item: $viewModel.activeSheet) { type in
                switch type {
                case .template: CardTemplateListView(rootSheet: $viewModel.activeSheet)
                case .custom: AddCardView()
                }
            }
            .sheet(item: $viewModel.cardToEdit) { card in
                AddCardView(cardToEdit: card)
            }
            // 👇 处理导入
            .fileImporter(
                isPresented: $viewModel.showFileImporter,
                allowedContentTypes: [.commaSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                viewModel.handleCardImport(result: result, context: context)
            }
            .alert("导入结果", isPresented: $viewModel.showImportAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(viewModel.importError ?? "未知错误")
            }
        
        }
    }
}

// 交易列表子视图
struct EmbeddedTransactionListView: View {
    let card: CreditCard
    @State private var selectedTransaction: Transaction? = nil
    @State private var transactionToEdit: Transaction?
    @Environment(\.modelContext) var context

    var sortedTransactions: [Transaction] {
        (card.transactions ?? []).sorted { $0.date > $1.date }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // 返现/积分上限使用进度（卡片图片与交易列表之间）
            CashbackProgressSection(card: card)
                .padding(.top, 5)

            if sortedTransactions.isEmpty {
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
                .cornerRadius(DesignConstants.CornerRadius.large)
                .padding(.horizontal, 16)
                
            } else {
                LazyVStack(spacing: DesignConstants.Spacing.listItemSpacing) {
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
            
            Spacer().frame(height: 50)
        }
    }
}
