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
    
    // 2. 控制当前显示的弹窗类型 (如果是 nil 就不弹)
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
                        // 长按删除功能
                        .contextMenu {
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
                // 👇 3. 修改这里：把 Button 换成 Menu
                ToolbarItem(placement: .primaryAction) {
                    
                    Menu {
                        // 选项 1: 从模板添加
                        Button(action: {
                            activeSheet = .template
                        }) {
                            Label("从模板添加", systemImage: "doc.on.doc")
                        }
                        
                        // 选项 2: 自定义添加
                        Button(action: {
                            activeSheet = .custom
                        }) {
                            Label("自定义添加", systemImage: "square.and.pencil")
                        }
                        
                    } label: {
                        // 菜单外面的图标 (还是那个加号)
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                    }
                }
            }
            // 👇 4. 统一处理弹窗逻辑
            // 只要 activeSheet 变了，这里就会弹出来
            .sheet(item: $activeSheet) { type in
                            switch type {
                            case .template:
                                // 👇 修改这里：把 $activeSheet 传进去
                                // 以前是 CardTemplateListView()
                                // 现在必须填上参数
                                CardTemplateListView(rootSheet: $activeSheet)
                                
                            case .custom:
                                AddCardView()
                            }
                        }
        }
    }
}

#Preview {
    // 预览需要的准备工作
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Transaction.self, CreditCard.self, configurations: config)
    SampleData.load(context: container.mainContext)
    return CardListView().modelContainer(container)
}
