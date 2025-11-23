//
//  AddTransactionView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import SwiftData // 👈 1. 别忘了引入这个

struct AddTransactionView: View {
    // 2. 拿到数据库操作手柄 (Context)
    @Environment(\.modelContext) var context
        // 4. 关闭页面的开关
    @Environment(\.dismiss) var dismiss
    @Query var cards: [CreditCard]
    

    // --- 表单的状态变量 ---
    @State private var merchant: String = ""
    @State private var amount: String = ""
    @State private var selectedCategory: Category = .dining
    @State private var date: Date = Date()
    @State private var selectedCardIndex: Int = 0
    @State private var location: Region = .cn // 默认在中国
    
    var currentCurrencySymbol: String {
            if cards.indices.contains(selectedCardIndex) {
                let card = cards[selectedCardIndex]
                // 👇 修改这里：直接问卡片要符号，不通过 Service 了
                return card.issueRegion.currencySymbol
            }
            return "¥"
        }
    
    var body: some View {
        NavigationView {
            Form {
                // --- 第一组：消费详情 ---
                Section(header: Text("消费详情")) {
                    TextField("商户名称 (例如：星巴克)", text: $merchant)
                    
                    HStack {
                        // 👇 这里修改：不再写死 "¥"，而是用动态变量
                        Text(currentCurrencySymbol)
                                                .fontWeight(.bold)
                                                .foregroundColor(.secondary)
                                            
                        TextField("0.00", text: $amount)
                                                .keyboardType(.decimalPad)
                    }
                    
                    // 类别选择
                    Picker("消费类别", selection: $selectedCategory) {
                        ForEach(Category.allCases, id: \.self) { category in
                            HStack {
                                Image(systemName: category.iconName)
                                    .foregroundColor(category.color)
                                Text(category.displayName)
                            }
                            .tag(category)
                        }
                    }
                    
                    // 地区选择 (之前定义的 Region 枚举)
                    Picker("消费地区", selection: $location) {
                        ForEach(Region.allCases, id: \.self) { region in
                            Text("\(region.icon) \(region.rawValue)")
                                .tag(region)
                        }
                    }
                }
                
                // --- 第二组：支付方式 ---
                Section(header: Text("支付方式")) {
                    Picker("选择信用卡", selection: $selectedCardIndex) {                        // 遍历 DataManager 里的卡片
                        ForEach(0..<cards.count, id: \.self) { index in
                            let card = cards[index]
                            HStack {
                                Text(card.bankName+" "+card.type)
                            }
                            .tag(index)
                        }
                    }
                    
                    DatePicker("消费日期", selection: $date, in: ...Date(), displayedComponents: .date)
                }
                
                // --- 第三组：实时预算返现 (调用 Service) ---
                Section {
                    HStack {
                        Text("预计返现")
                        Spacer()
                        
                        // 实时计算：造一个临时的 Transaction 对象来算费率
                        if let amountDouble = Double(amount) {
                            if cards.indices.contains(selectedCardIndex) { // 确保索引安全
                                let card = cards[selectedCardIndex]
                                
                                // 临时造个对象给 Service 算（不会存入数据库）
                                let tempTransaction = Transaction(
                                    merchant: merchant,
                                    category: selectedCategory,
                                    location: location,
                                    amount: amountDouble,
                                    date: date,
                                    card: card,
                                )
                                
                                let cashback = CashbackService.calculateCashback(for: tempTransaction)
                                
                                Text("\(currentCurrencySymbol)\(String(format: "%.2f", cashback))")
                                    .foregroundColor(.green)
                            }
                        }
                            else {
                            Text("¥0.00").foregroundColor(.gray)
                        }
                    }
                }
            }
            .navigationTitle("记一笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveTransaction() // 👈 点击保存
                    }
                    .disabled(merchant.isEmpty || amount.isEmpty)
                }
            }
        }
    }
    
    // --- 核心保存逻辑 ---
    func saveTransaction() {
            guard let amountDouble = Double(amount) else { return }
            
            // 👇 修改这里：从 cards 数组拿卡
            if cards.indices.contains(selectedCardIndex) {
                let card = cards[selectedCardIndex]
                
                let newTransaction = Transaction(
                    merchant: merchant,
                    category: selectedCategory,
                    location: location,
                    amount: amountDouble,
                    date: date,
                    card: card
                )
                
                context.insert(newTransaction)
                dismiss()
            }
        }
}

// 预览也需要注入环境
#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Transaction.self, CreditCard.self, configurations: config)
    
    SampleData.load(context: container.mainContext)
    
    // 👇 加上这个 return！
    return AddTransactionView()
        .modelContainer(container)
}

