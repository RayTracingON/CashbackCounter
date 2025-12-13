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
    @Query(sort: [
        SortDescriptor<CardTemplate>(\.bankName),
        SortDescriptor<CardTemplate>(\.type)
    ]) private var templates: [CardTemplate]

    // 1. 控制跳转的状态：存用户选了哪个模板
    @State private var selectedTemplate: CardTemplate?
    @Binding var rootSheet: SheetType?

    var body: some View {
        NavigationView {
            List(templates) { item in
                Button(action: {
                    // 👇 点击后，不直接保存，而是记录选了谁
                    selectedTemplate = item
                }) {
                    HStack {
                        Circle()
                            .fill(LinearGradient(colors: item.colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 40, height: 40)

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
            // 当 selectedTemplate 有值时，弹出 AddCardView，并把模板传进去
            .sheet(item: $selectedTemplate) { template in
                AddCardView(template: template, onSaved: {
                    // 当添加页保存成功时，执行这行代码：
                    // 把首页的 activeSheet 设为 nil，所有弹窗瞬间全部消失！
                    rootSheet = nil
                })
            }
        }
    }
}
