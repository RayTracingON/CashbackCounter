//
//  CardListView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

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
    
    // 控制编辑状态 (长按触发)
    @State private var cardToEdit: CreditCard?
    // 控制添加状态
    @State private var activeSheet: SheetType?
    
    // 核心状态：当前展开的卡片 ID
    @State private var selectedCardID: PersistentIdentifier? = nil
    
    // 👇 新增：计算属性，全视图通用
    private var isDetailMode: Bool {
        selectedCardID != nil
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
                    
                    ScrollView {
                        Spacer().frame(height: 240)
                        EmbeddedTransactionListView(card: selectedCard)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(0)
                }
                
                // --- 图层 2: 卡片列表 (在顶层) ---
                ScrollView(showsIndicators: false) {
                    ZStack(alignment: .top) {
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
                            // 控制位置和动画
                            .offset(y: isSelected ? 0 : (isDetailMode ? 800 : CGFloat(index * 220 + 20)))
                            // 控制透明度和缩放
                            .opacity(isDetailMode && !isSelected ? 0 : 1)
                            .scaleEffect(isDetailMode && !isSelected ? 0.9 : 1)
                            // 控制层级
                            .zIndex(isSelected ? 100 : Double(cards.count - index))
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
                            // 长按菜单
                            .contextMenu(isDetailMode ? nil : ContextMenu {
                                Button { cardToEdit = card } label: { Label("编辑卡片", systemImage: "pencil") }
                                Button(role: .destructive) { context.delete(card) } label: { Label("删除卡片", systemImage: "trash") }
                            })
                        }
                    }
                    // 👇 这里的报错应该消失了
                    .padding(.bottom, isDetailMode ? 0 : 100)
                }
                // 👇 这里的报错也应该消失了
                .scrollDisabled(isDetailMode)
                .zIndex(1)
                
            }
            // ... (导航栏和 Toolbar 代码保持不变) ...
            .navigationTitle(
                selectedCardID != nil
                ? (cards.first(where: {$0.id == selectedCardID})?.bankName ?? "")
                : "我的卡包"
            )
            .navigationBarTitleDisplayMode(selectedCardID != nil ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if selectedCardID != nil {
                        Button(action: {
                            withAnimation(springAnimation) {
                                selectedCardID = nil
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }
                    } else {
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
                                .padding(.vertical, 12) // 稍微增加一点高度
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
