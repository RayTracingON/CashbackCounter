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

// 长按拖动识别器（UIKit 桥接）。
// ⚠️ 不能用 SwiftUI 手势实现：LongPressGesture.sequenced(before: DragGesture)、
// onLongPressGesture、minimumDistance 为 0 的 DragGesture 挂在 ScrollView 内容上
// 都会不同程度抢占滚动手势（卡片铺满列表时整页无法滚动）。
// UILongPressGestureRecognizer 与 UIScrollView 的共存是系统级调校好的：
// 手指移动则长按失败、滚动照常；按住不动才触发，之后持续回调手指位置。
private struct ReorderLongPressGesture: UIViewRepresentable {
    var isEnabled: Bool
    var onBegan: () -> Void
    /// 手指相对按下点的纵向位移（窗口坐标系）
    var onChanged: (CGFloat) -> Void
    /// cancelled = true 表示被系统打断（如来电），应回弹而非落位
    var onEnded: (_ cancelled: Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        recognizer.minimumPressDuration = 0.2
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        uiView.gestureRecognizers?.forEach { $0.isEnabled = isEnabled }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: ReorderLongPressGesture
        private var startY: CGFloat = 0

        init(parent: ReorderLongPressGesture) {
            self.parent = parent
        }

        @objc func handle(_ gesture: UILongPressGestureRecognizer) {
            // 拖动期间列表滚动已禁用，窗口坐标系是稳定基准
            let y = gesture.location(in: nil).y
            switch gesture.state {
            case .began:
                startY = y
                parent.onBegan()
            case .changed:
                parent.onChanged(y - startY)
            case .ended:
                parent.onEnded(false)
            case .cancelled, .failed:
                parent.onEnded(true)
            default:
                break
            }
        }
    }
}

struct CardListView: View {
    // 按用户自定义顺序排列（长按拖动调整）；sortIndex 相同时按银行名兜底
    @Query(sort: [
        SortDescriptor(\CreditCard.sortIndex, order: .forward),
        SortDescriptor(\CreditCard.bankName, order: .forward),
    ])
    var cards: [CreditCard]
    @Environment(\.modelContext) var context
    
    // ViewModel
    @State private var viewModel = CardListViewModel()

    @AppStorage("mainCurrencyCode") private var mainCurrencyCode: String = "CNY"

    // 动画参数
    private let springAnimation = Animation.spring(response: 0.5, dampingFraction: 0.75, blendDuration: 0)

    // MARK: - 长按拖动排序状态

    /// 正在拖动的卡片；nil = 没有拖动
    @State private var draggedCardID: PersistentIdentifier? = nil
    /// 拖动中卡片当前应插入的显示位置（其余卡片据此让位）
    @State private var dragTargetIndex: Int? = nil
    /// 手指相对按下点的纵向位移
    @State private var dragTranslationY: CGFloat = 0

    /// 长按识别：抬起卡片，进入拖动状态
    private func beginReorder(card: CreditCard, at index: Int) {
        guard !viewModel.isDetailMode else { return }
        draggedCardID = card.id
        dragTargetIndex = index
        dragTranslationY = 0
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 拖动跟随：卡片跟手，手指每跨过一个槽位（stackOffset 高），目标位置移动一格
    private func updateReorder(card: CreditCard, at index: Int, translationY: CGFloat) {
        guard draggedCardID == card.id else { return }
        dragTranslationY = translationY
        let steps = (translationY / DesignConstants.CardList.stackOffset).rounded()
        let newTarget = min(max(index + Int(steps), 0), cards.count - 1)
        if newTarget != dragTargetIndex {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(springAnimation) {
                dragTargetIndex = newTarget
            }
        }
    }

    /// 松手落位（cancelled = 被系统打断，回弹不落位）
    private func endReorder(card: CreditCard, cancelled: Bool) {
        guard draggedCardID == card.id else { return }
        if !cancelled, let target = dragTargetIndex {
            withAnimation(springAnimation) {
                viewModel.moveCard(id: card.id, toDisplayIndex: target, cards: cards)
            }
        }
        withAnimation(springAnimation) {
            draggedCardID = nil
            dragTargetIndex = nil
            dragTranslationY = 0
        }
    }

    /// 拖动中，其余卡片为拖动卡让出位置的位移
    private func reorderShift(for index: Int) -> CGFloat {
        guard let draggedID = draggedCardID,
              let from = cards.firstIndex(where: { $0.id == draggedID }),
              let target = dragTargetIndex,
              index != from else { return 0 }
        if from < target, index > from, index <= target {
            return -DesignConstants.CardList.stackOffset // 拖动卡下移，途经的卡上移补位
        }
        if target < from, index >= target, index < from {
            return DesignConstants.CardList.stackOffset // 拖动卡上移，途经的卡下移补位
        }
        return 0
    }

    // 卡片堆叠列表：负间距 VStack 让每张卡占据真实槽位（stackOffset 高），
    // 选中/详情/拖动的位移都以槽位自然位置为基准换算
    private var cardStack: some View {
        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in

            // 计算当前卡片的状态
            let isSelected = card.id == viewModel.selectedCardID
            let isDragged = card.id == draggedCardID
            // 该卡在堆叠中的自然位置（相对内容区顶部），选中/详情模式的位移以此为基准换算
            let naturalY = CGFloat(index) * DesignConstants.CardList.stackOffset + DesignConstants.CardList.listTopPadding

            CreditCardView(
                bankName: card.bankName,
                type: card.type,
                endNum: card.endNum,
                colors: card.colors,
                cardImageData: card.cardImageData
            )
            .contentShape(Rectangle())
            // 控制位置和动画（相对于自身在 VStack 中的自然位置）
            .offset(y: {
                if isSelected {
                    // 选中时：停在当前滚动位置 + 顶部留白
                    return viewModel.scrollOffset + DesignConstants.CardList.selectedTopInset - naturalY
                }
                if viewModel.isDetailMode {
                    // 详情模式的未选中卡：推到屏幕外
                    return DesignConstants.CardList.detailPushDistance - naturalY
                }
                if isDragged {
                    // 拖动中：跟随手指
                    return dragTranslationY
                }
                // 其他卡：为拖动卡让位（无拖动时为 0）
                return reorderShift(for: index)
            }())
            // 控制透明度和缩放
            .opacity(viewModel.isDetailMode && !isSelected ? 0 : 1)
            .scaleEffect(viewModel.isDetailMode && !isSelected ? 0.9 : (isDragged ? 1.05 : 1))
            // 控制层级
            .zIndex(isDragged ? 500 : (isSelected ? 100 : Double(index)))
            .shadow(
                color: .black.opacity(isDragged ? 0.3 : (viewModel.isDetailMode ? 0.2 : 0.1)),
                radius: isDragged ? 24 : (viewModel.isDetailMode ? 20 : 10),
                x: 0, y: 5
            )
            .animation(springAnimation, value: isDragged)
            // 长按拖动排序（UIKit 桥接识别器，不干扰列表滚动；放在 onTapGesture 之前，
            // 避免 UIView 覆盖层挡住 SwiftUI 点击手势）
            .overlay(
                ReorderLongPressGesture(
                    isEnabled: !viewModel.isDetailMode,
                    onBegan: { beginReorder(card: card, at: index) },
                    onChanged: { updateReorder(card: card, at: index, translationY: $0) },
                    onEnded: { endReorder(card: card, cancelled: $0) }
                )
            )
            // 点击手势
            .onTapGesture {
                withAnimation(springAnimation) {
                    viewModel.toggleCardSelection(card)
                }
            }
        }
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                // 背景色
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                
                // --- 图层 1: 交易详情列表 (在最底层) ---
                if let selectedID = viewModel.selectedCardID,
                   let selectedCard = cards.first(where: { $0.id == selectedID }) {
                    
                    ScrollView(showsIndicators: false) {
                        EmbeddedTransactionListView(
                            card: selectedCard,
                            exchangeRates: viewModel.exchangeRates
                        )
                    }
                    // 按选中卡设置身份：换卡时整个滚动视图重建，滚动位置回到顶部
                    .id(selectedID)
                    .padding(.top, DesignConstants.CardList.transactionListTopPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(0)
                }
                
                // --- 图层 2: 卡片列表 (在顶层) ---
                ScrollView(showsIndicators: false) {
                    ZStack(alignment: .top) {
                        // 负间距 VStack：每张卡保留完整布局 frame，相邻卡重叠露出 stackOffset 高度
                        VStack(spacing: DesignConstants.CardList.stackOffset - DesignConstants.CardList.cardHeight) {
                            cardStack
                        }
                        .padding(.top, DesignConstants.CardList.listTopPadding)

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
                .scrollDisabled(viewModel.isDetailMode || draggedCardID != nil)
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
            .task {
                await viewModel.loadExchangeRates(mainCurrencyCode: mainCurrencyCode)
            }
            .onChange(of: mainCurrencyCode) { _, newCode in
                Task { await viewModel.loadExchangeRates(mainCurrencyCode: newCode) }
            }
            .navigationTitle(
                viewModel.selectedCardID != nil
                ? (cards.first(where: {$0.id == viewModel.selectedCardID})?.bankName ?? "")
                : String(localized: "我的卡包")
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
                            
                            // 延迟到按钮点击时才生成 ZIP，避免在视图构建时打包收据阻塞主线程
                            if !(selectedCard.transactions?.isEmpty ?? true) {
                                Button {
                                    let cardfli = viewModel.selectedCardTransactions(from: cards)
                                    viewModel.exportedFileURL = cardfli.exportReceiptsZip()
                                } label: {
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
                            
                            
                            // 同样延迟到点击时才生成 CSV
                            if !cards.isEmpty {
                                Button {
                                    viewModel.exportedFileURL = cards.exportCSVFile()
                                } label: {
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
            .sheet(isPresented: Binding(
                get: { viewModel.exportedFileURL != nil },
                set: { if !$0 { viewModel.exportedFileURL = nil } }
            )) {
                if let url = viewModel.exportedFileURL {
                    ActivityViewController(activityItems: [url])
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
    /// 以本币为基准的汇率表，交给交易行做外币返现折算
    var exchangeRates: [String: Double] = [:]
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
                        TransactionRow(transaction: item, exchangeRates: exchangeRates)
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
