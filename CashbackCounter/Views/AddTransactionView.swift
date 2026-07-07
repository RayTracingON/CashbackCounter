import SwiftUI
import SwiftData

struct AddTransactionView: View {
    // 1. 数据库与环境
    @Environment(\.modelContext) var context
    @Environment(\.dismiss) var dismiss
    @Query var cards: [CreditCard]
    
    // 2. 回调
    var onSaved: (() -> Void)? = nil
    
    // ViewModel
    @State private var viewModel: AddTransactionViewModel
    
    // --- 3. 自定义初始化 ---
    init(
        transaction: Transaction? = nil,
        image: UIImage? = nil,
        prefillMerchant: String? = nil,
        prefillAmount: Double? = nil,
        prefillBillingAmount: Double? = nil,
        prefillDate: Date? = nil,
        prefillCategory: Category? = nil,
        prefillLocation: Region? = nil,
        prefillPaymentMethod: PaymentMethod? = nil,
        prefillCardLast4: String? = nil,
        onSaved: (() -> Void)? = nil
    ) {
        self.onSaved = onSaved
        _viewModel = State(initialValue: AddTransactionViewModel(
            transaction: transaction,
            image: image,
            prefillMerchant: prefillMerchant,
            prefillAmount: prefillAmount,
            prefillBillingAmount: prefillBillingAmount,
            prefillDate: prefillDate,
            prefillCategory: prefillCategory,
            prefillLocation: prefillLocation,
            prefillPaymentMethod: prefillPaymentMethod,
            prefillCardLast4: prefillCardLast4
        ))
    }
    
    var body: some View {
        NavigationView {
            Form {
                // --- 第一组：消费详情 ---
                Section(header: Text("消费详情")) {
                    TextField("商户名称 (例如：星巴克)", text: $viewModel.merchant)

                    HStack {
                        Text(viewModel.location.currencySymbol)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                        
                        TextField("消费金额", text: $viewModel.amount)
                            .keyboardType(.decimalPad)
                    }
                    
                    Picker("消费类别", selection: $viewModel.selectedCategory) {
                        ForEach(Category.allCases, id: \.self) { c in
                            HStack {
                                Image(systemName: c.iconName).foregroundColor(c.color)
                                Text(c.displayName)
                            }
                            .tag(c)
                        }
                    }
                    
                    // 👇 新增：消费方式选择器
                    Picker("交易类型", selection: $viewModel.paymentMethod) {
                        ForEach(PaymentMethod.allCases, id: \.self) { method in
                            Label(method.displayName, systemImage: method.iconName)
                                .foregroundColor(method.color) // 使用我们在 Enum 里定义的颜色
                                .tag(method)
                        }
                    }
                    
                    Picker("消费地区", selection: $viewModel.location) {
                        ForEach(Region.allCases, id: \.self) { r in
                            Text("\(r.icon) \(r.rawValue)").tag(r)
                        }
                    }
                }

                
                // --- 第二组：收据凭证 ---
                Section(header: Text("收据凭证")) {
                    if let image = viewModel.receiptImage {
                        ZStack {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 200)
                                .cornerRadius(DesignConstants.CornerRadius.large)
                                .opacity(viewModel.isAnalyzing ? 0.5 : 1.0)
                                .onTapGesture {
                                    viewModel.showFullImage = true
                                }
                            
                            if viewModel.isAnalyzing {
                                ProgressView("AI 分析中...")
                                    .padding()
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(DesignConstants.CornerRadius.large)
                            }
                        }
                        .sheet(isPresented: $viewModel.showFullImage){
                            ReceiptFullScreenView(image: image)
                                .presentationDragIndicator(.visible)
                        }
                        Button(role: .destructive) {
                            viewModel.receiptImage = nil
                        } label: {
                            Label("删除图片", systemImage: "trash")
                        }
                        
                        Button {
                            viewModel.showImagePicker = true
                        } label: {
                            Label("重新上传", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } else {
                        Button {
                            viewModel.showImagePicker = true
                        } label: {
                            Label("上传收据图片", systemImage: "photo.on.rectangle")
                        }
                    }
                }
            
                
                // --- 第三组：支付账户与日期 ---
                Section(header: Text("支付账户")) {
                    if cards.isEmpty {
                        Text("请先添加信用卡").foregroundColor(.secondary)
                    } else {
                        Picker("选择信用卡", selection: $viewModel.selectedCardIndex) {
                            ForEach(0..<cards.count, id: \.self) { index in
                                Text(cards[index].bankName + " " + cards[index].type).tag(index)
                            }
                        }
                    }
                    
                    if cards.indices.contains(viewModel.selectedCardIndex) {
                        let card = cards[viewModel.selectedCardIndex]
                        let billingRegion = viewModel.resolvedBillingRegion(cards: cards)
                        if viewModel.location.currencyCode != billingRegion.currencyCode {
                            HStack {
                                Text("入账金额 (\(billingRegion.currencySymbol))")
                                    .font(.caption).foregroundColor(.red)
                                Spacer()
                                TextField("实际扣款", text: $viewModel.billingAmountStr)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        if card.isDualCurrency, let secondary = card.secondaryRegion {
                            Picker("入账币种", selection: Binding(
                                get: { viewModel.resolvedBillingRegion(cards: cards) },
                                set: { newRegion in
                                    viewModel.billingRegionOverride = newRegion
                                    viewModel.updateBillingAmount(cards: cards)
                                    viewModel.updateRewardPreview(cards: cards)
                                }
                            )) {
                                Text(card.issueRegion.currencyCode).tag(card.issueRegion)
                                Text(secondary.currencyCode).tag(secondary)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    
                    DatePicker("消费日期", selection: $viewModel.date, in: ...Date(), displayedComponents: .date)
                }
                
                // --- 第四组：实时预算返现 ---
                Section {
                    HStack {
                        let isPoints = cards.indices.contains(viewModel.selectedCardIndex) && cards[viewModel.selectedCardIndex].rewardType == .points
                        Text(isPoints ? "预计积分价值" : "预计返现")
                        Spacer()
                        
                        if let preview = viewModel.rewardPreview {
                            HStack(spacing: 4) {
                                Text("\(viewModel.currentCurrencySymbol(cards: cards))\(String(format: "%.2f", preview.value))")
                                    .foregroundColor(preview.isCapped ? .orange : .green)
                                    .fontWeight(.bold)
                                
                                if preview.isCapped {
                                    Image(systemName: "exclamationmark.circle")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        } else {
                            // 金额无效或未选卡时
                            Text("¥0.00").foregroundColor(.gray)
                        }
                    }
                }
            }
            .navigationTitle(viewModel.transactionToEdit == nil ? "记一笔" : "编辑账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            await viewModel.saveTransaction(cards: cards, context: context)
                            dismiss()
                            onSaved?()
                        }
                    }
                        .disabled(viewModel.merchant.isEmpty || viewModel.amount.isEmpty || cards.isEmpty)
                }
            }
            .onAppear {
                if let t = viewModel.transactionToEdit, let card = t.card,
                   let index = cards.firstIndex(of: card) {
                    viewModel.selectedCardIndex = index
                } else {
                    // ⏱️ 提前预热 AI 模型：用户挑照片的几秒钟足够完成权重加载，
                    // 等真正调用解析时省掉冷启动延迟
                    OCRService.prewarmAI()
                    viewModel.applyPrefillCardSelection(cards: cards)
                    if viewModel.receiptImage != nil && viewModel.amount.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            viewModel.analyzeReceipt(cards: cards)
                        }
                    }
                }
                viewModel.updateRewardPreview(cards: cards)
            }
            .onChange(of: cards.count) { _, _ in
                viewModel.applyPrefillCardSelection(cards: cards)
                viewModel.updateRewardPreview(cards: cards)
            }
            .onChange(of: viewModel.receiptImage) { _, newImage in
                if newImage != nil { viewModel.analyzeReceipt(cards: cards) }
            }
            .onChange(of: viewModel.amount) {
                viewModel.updateBillingAmount(cards: cards)
                viewModel.updateRewardPreview(cards: cards)
            }
            .onChange(of: viewModel.location) {
                viewModel.billingRegionOverride = nil
                viewModel.updateBillingAmount(cards: cards)
                viewModel.updateRewardPreview(cards: cards)
            }
            .onChange(of: viewModel.selectedCardIndex) {
                viewModel.billingRegionOverride = nil
                viewModel.updateBillingAmount(cards: cards)
                viewModel.updateRewardPreview(cards: cards)
            }
            .onChange(of: viewModel.billingAmountStr) { viewModel.updateRewardPreview(cards: cards) }
            .onChange(of: viewModel.selectedCategory) { viewModel.updateRewardPreview(cards: cards) }
            .onChange(of: viewModel.paymentMethod) { viewModel.updateRewardPreview(cards: cards) }
            .onChange(of: viewModel.date) { viewModel.updateRewardPreview(cards: cards) }
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $viewModel.showImagePicker) {
                ImagePicker(selectedImage: $viewModel.receiptImage, sourceType: .photoLibrary)
            }
        }
    }
}
