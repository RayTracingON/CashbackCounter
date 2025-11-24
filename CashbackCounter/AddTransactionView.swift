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
    var transactionToEdit: Transaction? // 👈 传入要编辑的对象

    // --- 表单的状态变量 ---
    @State private var merchant: String = ""
    @State private var amount: String = ""
    @State private var selectedCategory: Category = .dining
    @State private var date: Date = Date()
    @State private var selectedCardIndex: Int = 0
    @State private var location: Region = .cn
    @State private var billingAmountStr: String = "" // 入账金额输入框
    @State private var receiptImage: UIImage? // 图片
    
    // --- 3. 新增：自定义初始化方法 ---
    init(transaction: Transaction? = nil, image: UIImage? = nil, onSaved: (() -> Void)? = nil) {
            self.transactionToEdit = transaction
            self.onSaved = onSaved
            
            if let t = transaction {
                // 📝 编辑模式：填充旧数据
                _merchant = State(initialValue: t.merchant)
                _amount = State(initialValue: String(t.amount))
                _billingAmountStr = State(initialValue: String(t.billingAmount))
                _selectedCategory = State(initialValue: t.category)
                _date = State(initialValue: t.date)
                _location = State(initialValue: t.location)
                
                if let data = t.receiptData {
                    _receiptImage = State(initialValue: UIImage(data: data))
                }
                // 注意：这里需要找到卡片的索引，稍后在 onAppear 里处理更安全，这里先默认0
            } else {
                // 🆕 新建模式
                _receiptImage = State(initialValue: image)
            }
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
                    Section(header: Text("消费详情")) {
                        TextField("商户", text: $merchant)
                        
                        // 1. 消费金额 (比如日元)
                        HStack {
                            Text(location.currencySymbol).foregroundStyle(.secondary) // 消费地货币符号
                            TextField("消费金额", text: $amount).keyboardType(.decimalPad)
                        }
                        
                        Picker("类别", selection: $selectedCategory) {
                            ForEach(Category.allCases, id: \.self) { c in
                                HStack {
                                    Image(systemName: c.iconName).foregroundColor(c.color)
                                    Text(c.displayName)
                                }
                                .tag(c)
                            }
                        }
                        
                        Picker("地区", selection: $location) {
                            ForEach(Region.allCases, id: \.self) { r in
                                Text("\(r.icon) \(r.rawValue)").tag(r)
                            }
                        }
                    }
                    
                    // 2. 支付方式
                    Section(header: Text("支付方式")) {
                        Picker("选择信用卡", selection: $selectedCardIndex) {
                            ForEach(0..<cards.count, id: \.self) { index in
                                Text(cards[index].bankName).tag(index)
                            }
                        }
                        
                        // 🔥 关键逻辑：如果“消费地货币”和“卡片货币”不同，显示入账金额框
                        if cards.indices.contains(selectedCardIndex) {
                            let card = cards[selectedCardIndex]
                            if location.currencySymbol != card.issueRegion.currencySymbol {
                                HStack {
                                    Text("入账金额 (\(card.issueRegion.currencySymbol))")
                                        .font(.caption).foregroundColor(.red)
                                    Spacer()
                                    TextField("实际扣款", text: $billingAmountStr)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        
                        DatePicker("日期", selection: $date, displayedComponents: .date)
                    }
                
                    // 3. 预览计算
                    Section {
                        HStack {
                            Text("预计返现")
                            Spacer()
                            if cards.indices.contains(selectedCardIndex) {
                                let card = cards[selectedCardIndex]
                                // 优先用填写的入账金额，没填就用消费金额
                                let finalAmount = Double(billingAmountStr) ?? Double(amount) ?? 0
                                            
                                let cashback = CashbackService.calculateCashback(
                                    billingAmount: finalAmount,
                                    category: selectedCategory,
                                    location: location,
                                    card: card
                                )
                                Text("\(card.issueRegion.currencySymbol)\(String(format: "%.2f", cashback))")
                                    .foregroundStyle(.green).bold()
                                }
                            }
                        }
                    }
                    .navigationTitle(transactionToEdit == nil ? "记一笔" : "编辑账单")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") { saveTransaction() } }
                    }
                    // ⚡️ 修正卡片索引：进入页面时，如果是编辑模式，自动选中那张卡
                    .onAppear {
                        if let t = transactionToEdit, let card = t.card,
                        let index = cards.firstIndex(of: card) {
                        selectedCardIndex = index
                        }
                    }
                }
            }
    
    // --- 核心保存逻辑 ---
    func saveTransaction() {
            guard let amountDouble = Double(amount) else { return }
            // 如果没填入账金额，就默认等于消费金额
            let billingDouble = Double(billingAmountStr) ?? amountDouble
            
            if cards.indices.contains(selectedCardIndex) {
                let card = cards[selectedCardIndex]
                let imageData = receiptImage?.jpegData(compressionQuality: 0.5)
                
                if let t = transactionToEdit {
                    // 📝 编辑模式：直接修改对象属性 (SwiftData 会自动保存)
                    t.merchant = merchant
                    t.amount = amountDouble
                    t.billingAmount = billingDouble
                    t.category = selectedCategory
                    t.date = date
                    t.location = location
                    t.card = card
                    if let img = imageData { t.receiptData = img }
                } else {
                    // 🆕 新建模式：插入新对象
                    let newT = Transaction(
                        merchant: merchant,
                        category: selectedCategory,
                        location: location,
                        amount: amountDouble,
                        date: date,
                        card: card,
                        receiptData: imageData,
                        billingAmount: billingDouble, // 存入账金额
                    )
                    context.insert(newT)
                }
                dismiss()
                onSaved?()
            }
        }
    }

