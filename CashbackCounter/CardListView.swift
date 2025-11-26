import SwiftData
import SwiftUI

// 定义弹窗类型
enum SheetType: Identifiable {
    case template
    case custom
    var id: Int { hashValue }
}

struct CardListView: View {
    @Query var cards: [CreditCard]
    @Environment(\.modelContext) var context
    
    // 控制编辑/添加状态
    @State private var cardToEdit: CreditCard?
    @State private var activeSheet: SheetType?
    
    // 核心状态：当前选中的卡片 ID
    @State private var selectedCardID: PersistentIdentifier? = nil
    
    // 🪄 动画命名空间
    @Namespace private var animation
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                // 全局背景
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                
                // 🪄 核心逻辑：状态切换
                if let selectedID = selectedCardID,
                   let selectedCard = cards.first(where: { $0.id == selectedID }) {
                    
                    // --- 状态 B: 详情模式 ---
                    DetailView(card: selectedCard)
                    
                } else {
                    
                    // --- 状态 A: 列表模式 ---
                    CardStackView
                }
            }
            .navigationTitle(selectedCardID != nil ? "" : "我的卡包")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if selectedCardID != nil {
                        // 关闭按钮
                        Button(action: {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                                selectedCardID = nil
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.gray.opacity(0.6))
                        }
                    } else {
                        // 添加按钮
                        Menu {
                            Button(action: { activeSheet = .template }) { Label("从模板添加", systemImage: "doc.on.doc") }
                            Button(action: { activeSheet = .custom }) { Label("自定义添加", systemImage: "square.and.pencil") }
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 24))
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
        }
    }
    
    // MARK: - 视图组件 A: 卡片列表 (平铺模式)
    var CardStackView: some View {
        ScrollView(showsIndicators: false) {
            // 👇 修改点：使用正数间距 (20)，实现平铺
            VStack(spacing: 5) {
                
                // 顶部留白
                Color.clear.frame(height: 10)
                
                ForEach(cards) { card in
                    CreditCardView(
                        bankName: card.bankName,
                        type: card.type,
                        endNum: card.endNum,
                        colors: card.colors
                    )
                    .frame(height: 220)
                    // 🪄 匹配ID：我是源头
                    .matchedGeometryEffect(id: card.id, in: animation)
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                    // 点击展开
                    .onTapGesture {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                            selectedCardID = card.id
                        }
                    }
                    // 长按菜单
                    .contextMenu {
                        Button { cardToEdit = card } label: { Label("编辑卡片", systemImage: "pencil") }
                        Button(role: .destructive) { context.delete(card) } label: { Label("删除卡片", systemImage: "trash") }
                    }
                }
                
                // 底部留白，防止被 TabBar 遮挡
                Color.clear.frame(height: 100)
            }
            .padding(.horizontal)
        }
    }
    
    // MARK: - 视图组件 B: 详情视图
    func DetailView(card: CreditCard) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // 1. 顶部的卡片
                CreditCardView(
                    bankName: card.bankName,
                    type: card.type,
                    endNum: card.endNum,
                    colors: card.colors
                )
                .frame(height: 220)
                // 🪄 匹配ID：我是目的地 (自动从列表位置飞过来)
                .matchedGeometryEffect(id: card.id, in: animation)
                .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                .padding(.top, 10)
                .padding(.horizontal)
                .onTapGesture {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                        selectedCardID = nil
                    }
                }
                
                // 2. 交易列表
                EmbeddedTransactionListView(card: card)
                    .frame(minHeight: 500) // 最小高度
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.top, 20)
            }
        }
    }
}

struct EmbeddedTransactionListView: View {
    let card: CreditCard
    
    // 按日期倒序排列交易
    var sortedTransactions: [Transaction] {
        (card.transactions ?? []).sorted { $0.date > $1.date }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            
            // 列表标题
            Text("最新交易")
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.leading, 16)
                .padding(.bottom, 8)
                .padding(.top, 20)
            
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
                .padding(.vertical, 40)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                
            } else {
                // 交易列表容器
                LazyVStack(spacing: 0) {
                    ForEach(sortedTransactions) { transaction in
                        VStack(spacing: 0) {
                            // 复用你已有的 TransactionRow 组件
                            TransactionRow(transaction: transaction)
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                            
                            // 分割线 (除最后一行外)
                            if transaction != sortedTransactions.last {
                                Divider()
                                    .padding(.leading, 60)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }
            
            // 底部垫高，防止被 TabBar 遮挡
            Spacer().frame(height: 50)
        }
    }
}
