//
//  AddTransactionView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import SwiftData

struct AddTransactionView: View {
    // 1. 数据库与环境
    @Environment(\.modelContext) var context
    @Environment(\.dismiss) var dismiss
    @Query var cards: [CreditCard]
    
    // 2. 回调函数 (用于保存后通知父页面，比如关闭相机页)
    var onSaved: (() -> Void)? = nil

    // --- 表单的状态变量 ---
    @State private var merchant: String = ""
    @State private var amount: String = ""
    @State private var selectedCategory: Category = .dining
    @State private var date: Date = Date()
    @State private var selectedCardIndex: Int = 0
    @State private var location: Region = .cn
    @State private var receiptImage: UIImage? // 图片
    
    // --- 3. 新增：自定义初始化方法 ---
    init(image: UIImage? = nil, onSaved: (() -> Void)? = nil) {
        self.onSaved = onSaved
        // 如果外部传了图片进来，就赋值给 receiptImage
        _receiptImage = State(initialValue: image)
    }
    
    // 动态获取货币符号
    var currentCurrencySymbol: String {
        if cards.indices.contains(selectedCardIndex) {
            let card = cards[selectedCardIndex]
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
                    
                    // 地区选择
                    Picker("消费地区", selection: $location) {
                        ForEach(Region.allCases, id: \.self) { region in
                            Text("\(region.icon) \(region.rawValue)")
                                .tag(region)
                        }
                    }
                }
                
                // --- 第二组：收据图片预览 (如果有) ---
                if let image = receiptImage {
                    Section(header: Text("收据凭证")) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .cornerRadius(10)
                    }
                }
                
                // --- 第三组：支付方式 ---
                Section(header: Text("支付方式")) {
                    Picker("选择信用卡", selection: $selectedCardIndex) {
                        ForEach(0..<cards.count, id: \.self) { index in
                            let card = cards[index]
                            HStack {
                                Text(card.bankName + " " + card.type)
                            }
                            .tag(index)
                        }
                    }
                    
                    DatePicker("消费日期", selection: $date, in: ...Date(), displayedComponents: .date)
                }
                
                // --- 第四组：实时预算返现 ---
                Section {
                    HStack {
                        Text("预计返现")
                        Spacer()
                        
                        // 🛠️ 修复了这里的语法错误：使用逗号合并条件
                        if let amountDouble = Double(amount),
                           cards.indices.contains(selectedCardIndex) {
                            
                            let card = cards[selectedCardIndex]

                            let cashback = CashbackService.calculateCashback(
                                amount: amountDouble,
                                category: selectedCategory,
                                location: location,
                                card: card
                            )
                                                        
                            Text("\(currentCurrencySymbol)\(String(format: "%.2f", cashback))")
                                .foregroundColor(.green)
                                .fontWeight(.bold)
                        } else {
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
                        saveTransaction()
                    }
                    .disabled(merchant.isEmpty || amount.isEmpty)
                }
            }
        }
    }
    
    // --- 核心保存逻辑 ---
    func saveTransaction() {
        guard let amountDouble = Double(amount) else { return }
        
        if cards.indices.contains(selectedCardIndex) {
            let card = cards[selectedCardIndex]
            
            // 1. 压缩图片 (如果有图片，压缩成 0.5 质量的 Data)
            let imageData = receiptImage?.jpegData(compressionQuality: 0.5)
            
            let newTransaction = Transaction(
                merchant: merchant,
                category: selectedCategory,
                location: location,
                amount: amountDouble,
                date: date,
                card: card,
                receiptData: imageData // 👈 存入数据库
            )
            
            context.insert(newTransaction)
            
            // 2. 关闭页面
            dismiss()
            
            // 3. 执行回调 (比如通知相机页面关闭)
            onSaved?()
        }
    }
}

