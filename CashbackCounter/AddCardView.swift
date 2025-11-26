//
//  AddCardView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import SwiftData

struct AddCardView: View {
    @Environment(\.modelContext) var context
    @Environment(\.dismiss) var dismiss
    
    // 1. 接收要编辑的卡片 (如果是 nil 就是添加模式)
    var cardToEdit: CreditCard?
    var onSaved: (() -> Void)? = nil
    
    // --- 表单状态 ---
    @State private var bankName: String
    @State private var cardType: String
    @State private var endNum: String
    
    @State private var color1: Color
    @State private var color2: Color
    @State private var region: Region
    
    @State private var defaultRateStr: String
    @State private var foreignRateStr: String
    @State private var diningRateStr: String = ""
    @State private var groceryRateStr: String = ""
    @State private var travelRateStr: String = ""
    @State private var digitalRateStr: String = ""
    @State private var otherRateStr: String = ""
    
    // 👇 新增：上限设置 (Cap) 变量
    @State private var localBaseCapStr: String = ""   // 本币基础上限
    @State private var foreignBaseCapStr: String = "" // 外币基础上限
    
    // 各个类别的加成上限
    @State private var diningCapStr: String = ""
    @State private var groceryCapStr: String = ""
    @State private var travelCapStr: String = ""
    @State private var digitalCapStr: String = ""
    @State private var otherCapStr: String = ""
    
    // --- 2. 核心：自定义初始化 ---
    init(template: CardTemplate? = nil, cardToEdit: CreditCard? = nil, onSaved: (() -> Void)? = nil) {
        self.cardToEdit = cardToEdit
        self.onSaved = onSaved
        
        // 逻辑 A: 如果是编辑模式 (cardToEdit 有值) -> 填充旧数据
        if let card = cardToEdit {
            _bankName = State(initialValue: card.bankName)
            _cardType = State(initialValue: card.type)
            _endNum = State(initialValue: card.endNum)
            
            // 颜色回填 (利用 computed property 直接拿 Color)
            if card.colors.count >= 2 {
                _color1 = State(initialValue: card.colors[0])
                _color2 = State(initialValue: card.colors[1])
            } else {
                _color1 = State(initialValue: .blue)
                _color2 = State(initialValue: .purple)
            }
            
            _region = State(initialValue: card.issueRegion)
            
            // 费率回填 (注意：数据库存的是 0.01，界面显示要 *100 变成 "1.0")
            _defaultRateStr = State(initialValue: String(card.defaultRate * 100))
            
            if let foreignRate = card.foreignCurrencyRate {
                _foreignRateStr = State(initialValue: String(foreignRate * 100))
            } else {
                _foreignRateStr = State(initialValue: "")
            }
            if let rate = card.specialRates[.dining] {
                _diningRateStr = State(initialValue: String(rate * 100))
            }
            if let rate = card.specialRates[.grocery] {
                _groceryRateStr = State(initialValue: String(rate * 100))
            }
            if let rate = card.specialRates[.travel] {
                _travelRateStr = State(initialValue: String(rate * 100))
            }
            if let rate = card.specialRates[.digital] {
                _digitalRateStr = State(initialValue: String(rate * 100))
            }
            if let rate = card.specialRates[.other] {
                _otherRateStr = State(initialValue: String(rate * 100))
            }
            
            // 👇 新增：回填上限数据 (如果是 0 就不显示，留空代表无上限)
            if card.localBaseCap > 0 { _localBaseCapStr = State(initialValue: String(format: "%.0f", card.localBaseCap)) }
            if card.foreignBaseCap > 0 { _foreignBaseCapStr = State(initialValue: String(format: "%.0f", card.foreignBaseCap)) }
            
            // 回填类别上限 (从字典取)
            if let cap = card.categoryCaps[.dining], cap > 0 { _diningCapStr = State(initialValue: String(format: "%.0f", cap)) }
            if let cap = card.categoryCaps[.grocery], cap > 0 { _groceryCapStr = State(initialValue: String(format: "%.0f", cap)) }
            if let cap = card.categoryCaps[.travel], cap > 0 { _travelCapStr = State(initialValue: String(format: "%.0f", cap)) }
            if let cap = card.categoryCaps[.digital], cap > 0 { _digitalCapStr = State(initialValue: String(format: "%.0f", cap)) }
            if let cap = card.categoryCaps[.other], cap > 0 { _otherCapStr = State(initialValue: String(format: "%.0f", cap)) }
            
        }
        // 逻辑 B: 如果是模板模式 -> 填充模板数据 ***还没改
        else if let template = template {
            _bankName = State(initialValue: template.bankName)
            _cardType = State(initialValue: template.type)
            _endNum = State(initialValue: "") // 模板不带尾号
            
            
            if template.colors.count >= 2 {
                _color1 = State(initialValue: Color(hex: template.colors[0]))
                _color2 = State(initialValue: Color(hex: template.colors[1]))
            } else {
                _color1 = State(initialValue: .blue)
                _color2 = State(initialValue: .purple)
            }
            
            _region = State(initialValue: template.region)
            let defStr = String(format: "%.1f", template.defaultRate)
            _defaultRateStr = State(initialValue: defStr.replacingOccurrences(of: ".0", with: ""))
            
            if let fr = template.foreignCurrencyRate {
                let frStr = String(format: "%.1f", fr)
                _foreignRateStr = State(initialValue: frStr.replacingOccurrences(of: ".0", with: ""))
            } else {
                _foreignRateStr = State(initialValue: "")
            }
            
            // 5. ✅ 填充特殊返现率 (从字典里拆出来填给对应的 State)
            // 餐饮
            if let dining = template.specialRate[.dining] {
                let s = String(format: "%.1f", dining).replacingOccurrences(of: ".0", with: "")
                _diningRateStr = State(initialValue: s)
            }
            // 超市
            if let grocery = template.specialRate[.grocery] {
                let s = String(format: "%.1f", grocery).replacingOccurrences(of: ".0", with: "")
                _groceryRateStr = State(initialValue: s)
            }
            // 出行
            if let travel = template.specialRate[.travel] {
                let s = String(format: "%.1f", travel).replacingOccurrences(of: ".0", with: "")
                _travelRateStr = State(initialValue: s)
            }
            // 数码
            if let digital = template.specialRate[.digital] {
                let s = String(format: "%.1f", digital).replacingOccurrences(of: ".0", with: "")
                _digitalRateStr = State(initialValue: s)
            }
            // 其他
            if let other = template.specialRate[.other] {
                let s = String(format: "%.1f", other).replacingOccurrences(of: ".0", with: "")
                _otherRateStr = State(initialValue: s)
            }
        }
        // 逻辑 C: 纯新建模式 -> 全部给空值/默认值
        else {
            _bankName = State(initialValue: "")
            _cardType = State(initialValue: "")
            _endNum = State(initialValue: "")
            _color1 = State(initialValue: .blue)
            _color2 = State(initialValue: .purple)
            _region = State(initialValue: .cn)
            _defaultRateStr = State(initialValue: "1.0")
            _foreignRateStr = State(initialValue: "")
        }
    }
    
    var body: some View {
        NavigationView {
            Form {
                // 1. 实时预览
                Section {
                    CreditCardView(
                        bankName: bankName.isEmpty ? "银行名称" : bankName,
                        type: cardType.isEmpty ? "卡种" : cardType,
                        endNum: endNum.isEmpty ? "8888" : endNum,
                        colors: [color1, color2]
                    )
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
                
                // 2. 基本信息
                Section(header: Text("基本信息")) {
                    TextField("银行 (如: 招商银行)", text: $bankName)
                    TextField("卡种 (如: 运通白金)", text: $cardType)
                    TextField("尾号 (后四位)", text: $endNum)
                        .keyboardType(.numberPad)
                        .onChange(of: endNum) { oldValue, newValue in
                            if newValue.count > 4 { endNum = String(newValue.prefix(4)) }
                        }
                }
                
                // 3. 颜色设置
                Section(header: Text("卡面风格")) {
                    ColorPicker("渐变色 1", selection: $color1)
                    ColorPicker("渐变色 2", selection: $color2)
                }
                
                // 4. 规则设置
                Section(header: Text("基础返现 (所有消费)")) {
                    Picker("发行地区", selection: $region) {
                        ForEach(Region.allCases, id: \.self) { r in
                            Text("\(r.icon) \(r.rawValue)").tag(r)
                        }
                    }
                    
                    // --- 本币基础 ---
                    HStack {
                        Text("本币返现率 (%)")
                        Spacer()
                        TextField("1.0", text: $defaultRateStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 50)
                    }
                    HStack {
                        Text("本币年上限")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        TextField("无上限", text: $localBaseCapStr) // 👈 新增
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    
                    // --- 外币基础 ---
                    HStack {
                        Text("外币返现率 (%)")
                        Spacer()
                        TextField("同本币", text: $foreignRateStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 50)
                    }
                    HStack {
                        Text("外币年上限")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        TextField("无上限", text: $foreignBaseCapStr) // 👈 新增
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }
                Section(header: Text("类别加成 (额外叠加)")) {
                    // 使用一个辅助 View 来减少重复代码 (在下方定义)
                    CategoryInputRow(name: "餐饮", rate: $diningRateStr, cap: $diningCapStr)
                    CategoryInputRow(name: "超市", rate: $groceryRateStr, cap: $groceryCapStr)
                    CategoryInputRow(name: "出行", rate: $travelRateStr, cap: $travelCapStr)
                    CategoryInputRow(name: "数码", rate: $digitalRateStr, cap: $digitalCapStr)
                    CategoryInputRow(name: "其他", rate: $otherRateStr, cap: $otherCapStr)
                }
                
            }
            // 动态标题：有 cardToEdit 就是“编辑”，否则是“添加”
            .navigationTitle(cardToEdit == nil ? "添加信用卡" : "编辑卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveCard() }
                        .disabled(bankName.isEmpty || cardType.isEmpty)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
    
    // --- 3. 核心保存逻辑 ---
    func saveCard() {
        // 1. 处理费率 (保持不变)
        let defaultRate = (Double(defaultRateStr) ?? 0) / 100.0
        var foreignRate: Double? = nil
        if !foreignRateStr.isEmpty {
            foreignRate = (Double(foreignRateStr) ?? 0) / 100.0
        }
        
        // 2. 处理颜色 (保持不变)
        let c1Hex = color1.toHex() ?? "0000FF"
        let c2Hex = color2.toHex() ?? "000000"
        
        // 3. 处理类别加成率 (保持不变)
        var specialRates: [Category: Double] = [:]
        if let rate = Double(diningRateStr), rate > 0 { specialRates[.dining] = rate / 100.0 }
        if let rate = Double(groceryRateStr), rate > 0 { specialRates[.grocery] = rate / 100.0 }
        if let rate = Double(travelRateStr), rate > 0 { specialRates[.travel] = rate / 100.0 }
        if let rate = Double(digitalRateStr), rate > 0 { specialRates[.digital] = rate / 100.0 }
        if let rate = Double(otherRateStr), rate > 0 { specialRates[.other] = rate / 100.0 }
        
        // 👇 4. 处理新字段：上限 (Caps)
        let locBaseCap = Double(localBaseCapStr) ?? 0
        let forBaseCap = Double(foreignBaseCapStr) ?? 0
        
        var catCaps: [Category: Double] = [:]
        if let cap = Double(diningCapStr), cap > 0 { catCaps[.dining] = cap }
        if let cap = Double(groceryCapStr), cap > 0 { catCaps[.grocery] = cap }
        if let cap = Double(travelCapStr), cap > 0 { catCaps[.travel] = cap }
        if let cap = Double(digitalCapStr), cap > 0 { catCaps[.digital] = cap }
        if let cap = Double(otherCapStr), cap > 0 { catCaps[.other] = cap }
        
        
        if let existingCard = cardToEdit {
            // 编辑模式
            existingCard.bankName = bankName
            existingCard.type = cardType
            existingCard.endNum = endNum
            existingCard.colorHexes = [c1Hex, c2Hex]
            existingCard.defaultRate = defaultRate
            existingCard.issueRegion = region
            existingCard.foreignCurrencyRate = foreignRate
            existingCard.specialRates = specialRates
            
            // 👇 更新新属性
            existingCard.localBaseCap = locBaseCap
            existingCard.foreignBaseCap = forBaseCap
            existingCard.categoryCaps = catCaps
            
        } else {
            // 新建模式
            let newCard = CreditCard(
                bankName: bankName,
                type: cardType,
                endNum: endNum,
                colorHexes: [c1Hex, c2Hex],
                defaultRate: defaultRate,
                specialRates: specialRates,
                issueRegion: region,
                foreignCurrencyRate: foreignRate,
                // 👇 传入新属性
                localBaseCap: locBaseCap,
                foreignBaseCap: forBaseCap,
                categoryCaps: catCaps
            )
            context.insert(newCard)
        }
        
        dismiss()
        onSaved?()
    }
    
    struct CategoryInputRow: View {
        let name: String
        @Binding var rate: String
        @Binding var cap: String
        
        var body: some View {
            VStack(spacing: 8) {
                HStack {
                    Text(name)
                        .fontWeight(.medium)
                    Spacer()
                    // 费率输入
                    Text("加成%")
                        .font(.caption).foregroundColor(.gray)
                    TextField("0", text: $rate)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 40)
                        .padding(5)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(5)
                    
                    // 上限输入
                    Text("上限")
                        .font(.caption).foregroundColor(.gray)
                    TextField("无", text: $cap)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .padding(5)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(5)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
