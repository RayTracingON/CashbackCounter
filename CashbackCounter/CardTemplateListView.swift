//
//  CardTemplateListView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import SwiftData

struct CardTemplate: Identifiable {
    let id = UUID()
    let bankName: String
    let type: String
    let colors: [String]
    let region: Region
    
    
    static let examples: [CardTemplate] = [
        CardTemplate(bankName: "Apple", type: "Card", colors: ["EEEEEE", "FFFFFF"], region: .us),
        CardTemplate(bankName: "招商银行", type: "运通百夫长", colors: ["000000", "333333"], region: .cn),
        CardTemplate(bankName: "中国银行", type: "冬奥白金", colors: ["FF0000", "FF7F50"], region: .cn),
        CardTemplate(bankName: "Amex", type: "Platinum", colors: ["C0C0C0", "E0E0E0"], region: .us),
        CardTemplate(bankName: "Chase", type: "Sapphire", colors: ["0000FF", "000080"], region: .us)
    ]
}

struct CardTemplateListView: View {
    @Environment(\.modelContext) var context
    @Environment(\.dismiss) var dismiss
    // 1. 控制跳转的状态：存用户选了哪个模板
    @State private var selectedTemplate: CardTemplate?
    @Binding var rootSheet: SheetType?
    
    // 定义一些预设的模板数据

    
    var body: some View {
            NavigationView {
                List(CardTemplate.examples) { item in
                    Button(action: {
                        // 👇 点击后，不直接保存，而是记录选了谁
                        selectedTemplate = item
                    }) {
                        HStack {
                            // ... (原来的 UI 代码不变) ...
                            Circle()
                                .fill(LinearGradient(colors: item.colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 40, height: 40)
                            
                            VStack(alignment: .leading) {
                                Text(item.bankName).font(.headline)
                                Text(item.type).font(.caption).foregroundColor(.gray)
                            }
                            
                            Spacer()
                            // 图标改成“箭头”，暗示会跳转
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

#Preview {
    // 使用 .constant 来模拟一个 Binding
    CardTemplateListView(rootSheet: .constant(.template))
        .modelContainer(for: CreditCard.self, inMemory: true)
}
