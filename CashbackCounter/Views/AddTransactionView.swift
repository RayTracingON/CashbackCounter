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
    
    // 2. 回调与编辑对象
    var onSaved: (() -> Void)? = nil
    var transactionToEdit: Transaction?
    
    // --- 表单的状态变量 ---
    @State private var merchant: String = ""
    @State private var amount: String = ""
    @State private var selectedCategory: Category = .dining
    @State private var date: Date = Date()
    @State private var selectedCardIndex: Int = 0
    @State private var location: Region = .cn
    @State private var billingAmountStr: String = ""
    @State private var receiptImage: UIImage?
    
    // 👇 新增：控制 AI 分析的加载状态
    @State private var isAnalyzing: Bool = false
    
    // --- 3. 自定义初始化 ---
    init(transaction: Transaction? = nil, image: UIImage? = nil, onSaved: (() -> Void)? = nil) {
        self.transactionToEdit = transaction
        self.onSaved = onSaved
        
        if let t = transaction {
            // 编辑模式
            _merchant = State(initialValue: t.merchant)
            _amount = State(initialValue: String(t.amount))
            _billingAmountStr = State(initialValue: String(t.billingAmount))
            _selectedCategory = State(initialValue: t.category)
            _date = State(initialValue: t.date)
            _location = State(initialValue: t.location)
            
            if let data = t.receiptData {
                _receiptImage = State(initialValue: UIImage(data: data))
            }
        } else {
            // 新建模式 (可能带图)
            _receiptImage = State(initialValue: image)
        }
    }
    
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
                        Text(location.currencySymbol)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                        
                        TextField("消费金额", text: $amount)
                            .keyboardType(.decimalPad)
                    }
                    
                    Picker("消费类别", selection: $selectedCategory) {
                        ForEach(Category.allCases, id: \.self) { c in
                            HStack {
                                Image(systemName: c.iconName).foregroundColor(c.color)
                                Text(c.displayName)
                            }
                            .tag(c)
                        }
                    }
                    
                    Picker("消费地区", selection: $location) {
                        ForEach(Region.allCases, id: \.self) { r in
                            Text("\(r.icon) \(r.rawValue)").tag(r)
                        }
                    }
                }
                
                // --- 第二组：收据图片预览 + 加载状态 ---
                if let image = receiptImage {
                    Section(header: Text("收据凭证")) {
                        ZStack {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 200)
                                .cornerRadius(10)
                                .opacity(isAnalyzing ? 0.5 : 1.0) // 分析时变暗
                            
                            // 👇 分析时显示转圈圈
                            if isAnalyzing {
                                ProgressView("AI 分析中...")
                                    .padding()
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(10)
                            }
                        }
                    }
                }
                
                // --- 第三组：支付方式 ---
                Section(header: Text("支付方式")) {
                    Picker("选择信用卡", selection: $selectedCardIndex) {
                        ForEach(0..<cards.count, id: \.self) { index in
                            Text(cards[index].bankName + " " + cards[index].type).tag(index)
                        }
                    }
                    
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
                    
                    DatePicker("消费日期", selection: $date, in: ...Date(), displayedComponents: .date)
                }
                
                // --- 第四组：实时预算返现 ---
                Section {
                    HStack {
                        Text("预计返现")
                        Spacer()
                        if let amountDouble = Double(amount),
                           cards.indices.contains(selectedCardIndex) {
                            
                            let card = cards[selectedCardIndex]
                            let finalAmount = Double(billingAmountStr) ?? amountDouble
                            
                            // 👇 核心修改：调用卡片的 calculateCappedCashback
                            // 注意：必须传入 date，因为要查这一年的历史记录
                            let cashback = card.calculateCappedCashback(
                                amount: finalAmount,
                                category: selectedCategory,
                                location: location,
                                date: date,
                                transactionToExclude: transactionToEdit // 👈 预览时排除旧值
                            )
                            
                            // 计算理论返现 (如果不受限应该拿多少)，用来判断是否变色
                            let theoretical = finalAmount * card.getRate(for: selectedCategory, location: location)
                            
                            HStack(spacing: 4) {
                                Text("\(currentCurrencySymbol)\(String(format: "%.2f", cashback))")
                                    .foregroundColor(cashback < theoretical - 0.01 ? .orange : .green) // 如果被砍了(比理论少)，显示橙色
                                    .fontWeight(.bold)
                                
                                // 如果触发上限，加个小提示
                                if cashback < theoretical - 0.01 {
                                    Image(systemName: "exclamationmark.circle")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        } else {
                            Text("¥0.00").foregroundColor(.gray)
                        }
                    }
                }
            }
            .navigationTitle(transactionToEdit == nil ? "记一笔" : "编辑账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveTransaction() }
                        .disabled(merchant.isEmpty || amount.isEmpty)
                }
            }
            // ⚡️ 修正卡片索引
            .onAppear {
                // 如果是编辑模式，选中旧卡
                if let t = transactionToEdit, let card = t.card,
                   let index = cards.firstIndex(of: card) {
                    selectedCardIndex = index
                }
                // 👇 如果是新建模式且带图 (比如从相机直接跳转过来)，但还没分析过，触发分析
                else if receiptImage != nil && amount.isEmpty {
                    // 稍微延迟一下，让界面先出来
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        analyzeReceipt()
                    }
                }
            }
            // 👇👇👇 核心：监听图片变化，触发 OCR
            .onChange(of: receiptImage) { oldValue, newImage in
                if newImage != nil {
                    analyzeReceipt()
                }
            }
            .onChange(of: amount) { updateBillingAmount() }
            .onChange(of: location) { updateBillingAmount() }
            .onChange(of: selectedCardIndex) { updateBillingAmount() }
            .scrollDismissesKeyboard(.interactively)
        }
    }
    
    // --- 4. 抽离出 AI 分析逻辑 ---
    func analyzeReceipt() {
        guard let image = receiptImage else { return }
        
        // 避免重复分析 (比如编辑模式进来已有数据)
        if !merchant.isEmpty || !amount.isEmpty { return }
        
        isAnalyzing = true // 开始转圈
        
        Task {
            // 调用我们之前写好的 OCRService
            let metadata = await OCRService.analyzeImage(image)
            
            await MainActor.run {
                isAnalyzing = false // 停止转圈
                
                if let data = metadata {
                    // 1. 填金额
                    if let amt = data.totalAmount {
                        self.amount = String(format: "%.2f", abs(amt))
                    }
                    // 2. 填商家
                    if let merch = data.merchant {
                        self.merchant = merch
                    }
                    // 3. 填日期
                    if let dateStr = data.dateString {
                        self.date = dateStr.toDate()
                    }
                    
                    // 4. 自动选卡 (匹配尾号)
                    if let last4 = data.cardLast4 {
                        if let index = cards.firstIndex(where: { $0.endNum == last4 }) {
                            self.selectedCardIndex = index
                        }
                    }
                    
                    // 5. 匹配商户类别
                    if let cat = data.category {
                        self.selectedCategory = cat
                    }
                    
                    // 5. 自动识别币种/地区
                    if let currency = data.currency {
                        if currency.contains("CNY") { self.location = .cn }
                        else if currency.contains("USD") { self.location = .us }
                        else if currency.contains("HKD") { self.location = .hk }
                        else if currency.contains("JPY") { self.location = .jp}
                        else if currency.contains("NZD") { self.location = .nz}
                        else if currency.contains("TWD") { self.location = .tw}
                        else { self.location = .other}
                        
                    }
                }
            }
        }
    }
    
    // --- 核心保存逻辑 ---
    func saveTransaction() {
        guard let amountDouble = Double(amount) else { return }
        let billingDouble = Double(billingAmountStr) ?? amountDouble
        
        if cards.indices.contains(selectedCardIndex) {
            let card = cards[selectedCardIndex]
            let imageData = receiptImage?.jpegData(compressionQuality: 0.5)
            
            // 👇 1. 在保存前，先算出“最终返现额”
            let finalCashback = card.calculateCappedCashback(
                amount: billingDouble,
                category: selectedCategory,
                location: location,
                date: date,
                transactionToExclude: transactionToEdit // 👈 保存时排除旧值
            )
            
            // 2. 重新获取一次名义费率 (用于更新 rate 字段)
            let nominalRate = card.getRate(for: selectedCategory, location: location)
            
            if let t = transactionToEdit {
                // --- 编辑模式 ---
                t.merchant = merchant
                t.amount = amountDouble
                t.location = location
                t.date = date
                
                // 如果关键信息变了，更新关联属性
                if t.card != card || t.billingAmount != billingDouble || t.category != selectedCategory || t.date != date {
                    
                    t.card = card
                    t.billingAmount = billingDouble
                    t.category = selectedCategory
                    
                    // 更新费率
                    t.rate = nominalRate
                    // 👇 更新返现额 (直接赋值)
                    t.cashbackamount = finalCashback
                }
                
                if let img = imageData { t.receiptData = img }
                
            } else {
                // --- 新建模式 ---
                let newTransaction = Transaction(
                    merchant: merchant,
                    category: selectedCategory,
                    location: location,
                    amount: amountDouble,
                    date: date,
                    card: card,
                    receiptData: imageData,
                    billingAmount: billingDouble,
                    // 👇 传入算好的返现额
                    cashbackAmount: finalCashback,
                )
                context.insert(newTransaction)
            }
            
            dismiss()
            onSaved?()
        }
    }
    func updateBillingAmount() {
        guard let amountDouble = Double(amount) else { return }

        let sourceCurrency = location.currencyCode
        let card = cards[selectedCardIndex]
        let targetCurrency = card.issueRegion.currencyCode

        if sourceCurrency == targetCurrency {
            billingAmountStr = amount
            return
        }

        Task {
            let rates = await CurrencyService.getRates(base: sourceCurrency)
            let rate = rates[targetCurrency] ?? 1.0
            let billing = amountDouble * rate

            await MainActor.run {
                self.billingAmountStr = String(format: "%.2f", billing)
            }
        }
    }
}


