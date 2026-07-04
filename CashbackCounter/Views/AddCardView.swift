//
//  AddCardView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import SwiftData
import PhotosUI

struct AddCardView: View {
    @Environment(\.modelContext) var context
    @Environment(\.dismiss) var dismiss
    @StateObject private var imageManager = ImageDownloadManager()
    @Query(sort: [SortDescriptor(\Point.bankName, order: .forward)])
    private var points: [Point]
    
    // 1. 接收要编辑的卡片 (如果是 nil 就是添加模式)
    var cardToEdit: CreditCard?
    private let template: CardTemplate?
    var onSaved: (() -> Void)? = nil
    
    // ViewModel
    @State private var viewModel: AddCardViewModel
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    
    // --- 2. 核心：自定义初始化 ---
    init(template: CardTemplate? = nil, cardToEdit: CreditCard? = nil, onSaved: (() -> Void)? = nil) {
        self.cardToEdit = cardToEdit
        self.template = template
        self.onSaved = onSaved
        _viewModel = State(initialValue: AddCardViewModel(cardToEdit: cardToEdit, template: template))
    }
    
    var body: some View {
        NavigationView {
            Form {
                // 1. 实时预览
                Section {
                    VStack(spacing: 12) {
                        ZStack(alignment: .topTrailing) {
                            CreditCardView(
                                bankName: viewModel.bankName.isEmpty ? "银行名称" : viewModel.bankName,
                                type: viewModel.cardType.isEmpty ? "卡种" : viewModel.cardType,
                                endNum: viewModel.endNum.isEmpty ? "8888" : viewModel.endNum,
                                colors: [viewModel.color1, viewModel.color2],
                                cardImageData: viewModel.cardImageData
                            )
                            
                            // 👇 卡面图片操作按钮
                            if viewModel.cardImageData != nil {
                                // 已有卡面 → 显示删除按钮
                                Button {
                                    withAnimation { viewModel.cardImageData = nil }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title2)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.5))
                                }
                                .padding(24)
                            } else {
                                // 无卡面 → 显示上传按钮
                                Button {
                                    viewModel.showPhotoPicker = true
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 32))
                                        Text("上传卡面")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                    }
                                    .foregroundColor(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .padding(.horizontal)
                                .frame(height: 220)
                            }
                        }
                        
                        if imageManager.isDownloading {
                            ProgressView("正在下载卡面...", value: imageManager.downloadProgress, total: 1.0)
                                .padding(.top, 5)
                        }
                        
                        if let error = imageManager.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
                
                // 2. 基本信息
                Section(header: Text("基本信息")) {
                    TextField("银行 (如: 招商银行)", text: $viewModel.bankName)
                    TextField("卡种 (如: 运通白金)", text: $viewModel.cardType)
                    TextField("尾号 (后四位)", text: $viewModel.endNum)
                        .keyboardType(.numberPad)
                        .onChange(of: viewModel.endNum) { oldValue, newValue in
                            if newValue.count > 4 { viewModel.endNum = String(newValue.prefix(4)) }
                        }
                    TextField("备注 (可选)", text: $viewModel.memo)
                }
                
                HStack {
                    Text("还款日提醒 (每月)")
                    Spacer()
                    TextField("无", text: $viewModel.repaymentDayStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 50)
                    Text("日")
                        .foregroundColor(.secondary)
                }

                Section(header: Text("奖励类型")) {
                    Picker("奖励类型", selection: $viewModel.rewardType) {
                        ForEach(RewardType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                if viewModel.rewardType == .points {
                    Section(header: Text("积分库")) {
                        if points.isEmpty {
                            Text("暂无积分库，请先创建")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Picker("选择积分计划", selection: $viewModel.selectedPointID) {
                            Text("未选择").tag(UUID?.none)
                            ForEach(points) { point in
                                Text(point.displayName).tag(Optional(point.id))
                            }
                        }
                        Button("管理积分库") { viewModel.showPointLibrary = true }
                    }
                }
                
                // 3. 颜色设置
                Section(header: Text("卡面风格")) {
                    ColorPicker("渐变色 1", selection: $viewModel.color1)
                    ColorPicker("渐变色 2", selection: $viewModel.color2)
                }
                
                Section(header: Text(viewModel.capPeriodTitle)){
                    Picker(viewModel.capPeriodTitle, selection: $viewModel.capPeriod) {
                        Text("按月").tag(CapPeriod.monthly)
                        Text("按年").tag(CapPeriod.yearly)
                    }
                }
                .pickerStyle(.segmented)
                
                // 4. 规则设置 - 基础
                Section(header: Text(viewModel.baseSectionTitle)) {
                    Picker("发行地区", selection: $viewModel.region) {
                        ForEach(Region.allCases, id: \.self) { r in
                            Text("\(r.icon) \(r.rawValue)").tag(r)
                        }
                    }

                    Toggle("双币卡", isOn: $viewModel.isDualCurrency)
                    if viewModel.isDualCurrency {
                        Picker("第二币种地区", selection: $viewModel.secondaryRegion) {
                            ForEach(Region.allCases.filter { $0 != viewModel.region }, id: \.self) { r in
                                Text("\(r.icon) \(r.currencyCode)").tag(r)
                            }
                        }
                        Picker("上限模式", selection: $viewModel.dualCurrencyMode) {
                            ForEach(DualCurrencyMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        HStack {
                            Text("副币种费率 (%)")
                            Spacer()
                            TextField("同本币", text: $viewModel.secondaryRateStr)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 50)
                        }
                        Text("并入本币上限：仅第二币种地区消费入账副币，金额按 1:1 计入本币上限（如港币+人民币卡）。\n独立外币上限：所有境外消费入账副币种，使用外币费率与外币上限（如人民币+美元卡）。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text(viewModel.localRateTitle)
                        Spacer()
                        TextField("1.0", text: $viewModel.defaultRateStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 50)
                    }
                    HStack {
                        Text(viewModel.localCapTitle)
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        TextField("无上限", text: $viewModel.localBaseCapStr)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    
                    HStack {
                        Text(viewModel.foreignRateTitle)
                        Spacer()
                        TextField("同本币", text: $viewModel.foreignRateStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 50)
                    }
                    HStack {
                        Text(viewModel.foreignCapTitle)
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        TextField("无上限", text: $viewModel.foreignBaseCapStr)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }
                
                // 5. 规则设置 - 类别
                Section(header: Text("类别加成 (额外叠加)")) {
                    CategoryInputRow(name: "餐饮", rate: $viewModel.diningRateStr, cap: $viewModel.diningCapStr, capUnit: viewModel.rewardLabel)
                    CategoryInputRow(name: "超市", rate: $viewModel.groceryRateStr, cap: $viewModel.groceryCapStr, capUnit: viewModel.rewardLabel)
                    CategoryInputRow(name: "出行", rate: $viewModel.travelRateStr, cap: $viewModel.travelCapStr, capUnit: viewModel.rewardLabel)
                    CategoryInputRow(name: "数码", rate: $viewModel.digitalRateStr, cap: $viewModel.digitalCapStr, capUnit: viewModel.rewardLabel)
                    CategoryInputRow(name: "其他", rate: $viewModel.otherRateStr, cap: $viewModel.otherCapStr, capUnit: viewModel.rewardLabel)
                }
                
                // 6. 规则设置 - 支付方式
                Section(header: Text("支付方式规则 (可选)")) {
                    ForEach(PaymentMethod.allCases, id: \.self) { method in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(method.displayName, systemImage: method.iconName)
                                    .foregroundColor(method.color)
                                Spacer()
                            }
                            
                            HStack {
                                Text("加成:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                TextField("0", value: viewModel.rateBinding(for: method), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 50)
                                    .padding(4)
                                    .background(Color(uiColor: .secondarySystemBackground))
                                    .cornerRadius(DesignConstants.CornerRadius.small)
                                Text("%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                Text(viewModel.rewardType == .points ? "积分上限:" : "上限:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                TextField("无", value: viewModel.capBinding(for: method), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                    .padding(4)
                                    .background(Color(uiColor: .secondarySystemBackground))
                                    .cornerRadius(DesignConstants.CornerRadius.small)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
            }
            .navigationTitle(cardToEdit == nil ? "添加信用卡" : "编辑卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.saveCard(cardToEdit: cardToEdit, template: template, points: points, context: context)
                        dismiss()
                        onSaved?()
                    }
                    .disabled(!viewModel.isFormValid)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // 👇👇👇 核心修复：这里补上了监听器！
            // 1. 监听视图出现：如果有模版 URL 且没有图片，就开始下载
            .onAppear {
                if viewModel.cardImageData == nil, let url = template?.pictureURL {
                    Task {
                        await imageManager.downloadImage(from: url)
                    }
                }
                
                if cardToEdit == nil {
                    viewModel.matchPointProgram(from: points, template: template)
                }
            }
            // 2. 监听下载完成，将图片转为 Data
            .onChange(of: imageManager.downloadedImage) { _, newImage in
                if let image = newImage {
                    viewModel.cardImageData = image.jpegData(compressionQuality: AppConfig.receiptJPEGQuality)
                }
            }
            .onChange(of: viewModel.rewardType) { _, newValue in
                if newValue != .points {
                    viewModel.selectedPointID = nil
                }
            }
            .sheet(isPresented: $viewModel.showPointLibrary) {
                PointLibraryView()
            }
            .photosPicker(isPresented: $viewModel.showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        let compressed = uiImage.jpegData(compressionQuality: AppConfig.receiptJPEGQuality)
                        await MainActor.run {
                            withAnimation {
                                viewModel.cardImageData = compressed
                            }
                        }
                    }
                    selectedPhotoItem = nil
                }
            }
        }
    }
    
    struct CategoryInputRow: View {
        let name: String
        @Binding var rate: String
        @Binding var cap: String
        let capUnit: String
        
        var body: some View {
            VStack(spacing: 8) {
                HStack {
                    Text(name)
                        .fontWeight(.medium)
                    Spacer()
                    Text("加成%")
                        .font(.caption).foregroundColor(.gray)
                    TextField("0", text: $rate)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 40)
                        .padding(5)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(DesignConstants.CornerRadius.small)
                    
                    Text(capUnit == "积分" ? "积分上限" : "上限")
                        .font(.caption).foregroundColor(.gray)
                    TextField("无", text: $cap)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .padding(5)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(DesignConstants.CornerRadius.small)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
