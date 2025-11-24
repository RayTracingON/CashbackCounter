//
//  CardListView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftData
import SwiftUI

// 1. 定义弹窗类型 (为了区分是弹“模板”还是“自定义”)
enum SheetType: Identifiable {
    case template
    case custom
    
    var id: Int { hashValue }
}

struct CardListView: View {
    @Query var cards: [CreditCard]
    @Environment(\.modelContext) var context // 用来删除
    
    // 2. 控制编辑状态
    @State private var cardToEdit: CreditCard?
    
    // 3. 控制添加状态
    @State private var activeSheet: SheetType?
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    ForEach(cards) { card in
                        CreditCardView(
                            bankName: card.bankName,
                            type: card.type,
                            endNum: card.endNum,
                            colors: card.colors
                        )
                        // 👇 修改点 1：完善长按菜单
                        .contextMenu {
                            // ✏️ 编辑按钮
                            Button {
                                cardToEdit = card // 赋值后会自动触发下面的 sheet
                            } label: {
                                Label("编辑卡片", systemImage: "pencil")
                            }
                            
                            // 🗑️ 删除按钮
                            Button(role: .destructive) {
                                context.delete(card)
                            } label: {
                                Label("删除卡片", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.top)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("我的卡包")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: { activeSheet = .template }) {
                            Label("从模板添加", systemImage: "doc.on.doc")
                        }
                        Button(action: { activeSheet = .custom }) {
                            Label("自定义添加", systemImage: "square.and.pencil")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                    }
                }
            }
            // 弹窗 1: 处理添加 (模板/自定义)
            .sheet(item: $activeSheet) { type in
                switch type {
                case .template:
                    CardTemplateListView(rootSheet: $activeSheet)
                case .custom:
                    AddCardView()
                }
            }
            // 👇 修改点 2: 处理编辑弹窗
            // 只要 cardToEdit 变成非空，就会弹出这个窗口，并把卡片传进去
            .sheet(item: $cardToEdit) { card in
                AddCardView(cardToEdit: card)
            }
        }
    }
}


