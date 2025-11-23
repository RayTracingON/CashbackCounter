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
    // 👇 1. 新增：一个回调函数，如果不为 nil，就执行它
    var onSaved: (() -> Void)? = nil
    
    // --- 表单状态 ---
    @State private var bankName: String = ""
    @State private var cardType: String = ""
    @State private var endNum: String = ""
    
    // 默认颜色 (红配橙)
    @State private var color1: Color = .blue
    @State private var color2: Color = .purple
    
    // 地区
    @State private var region: Region = .cn
    
    // 费率
    @State private var defaultRateStr: String = "0"
    @State private var foreignRateStr: String = "0"
    @State private var diningRateStr: String = "0"
    @State private var groceryRateStr: String = "0"
    @State private var travelRateStr: String = "0"
    @State private var digitalRateStr: String = "0"
    @State private var otherRateStr: String = "0"
    
    init(template: CardTemplate? = nil, onSaved: (() -> Void)? = nil) {            // 1. 设置银行名称
            self.onSaved = onSaved
            _bankName = State(initialValue: template?.bankName ?? "")
            // 2. 设置卡种
            _cardType = State(initialValue: template?.type ?? "")
            
            // 3. 设置颜色 (把 Hex 转回 Color)
            if let colors = template?.colors, colors.count >= 2 {
                _color1 = State(initialValue: Color(hex: colors[0]))
                _color2 = State(initialValue: Color(hex: colors[1]))
            } else {
                _color1 = State(initialValue: .blue)
                _color2 = State(initialValue: .purple)
            }
            
            // 4. 设置地区
            _region = State(initialValue: template?.region ?? .cn)
        }
    
    var body: some View {
        NavigationView {
            Form {
                // 1. 卡片外观预览
                Section {
                    CreditCardView(
                        bankName: bankName.isEmpty ? "银行名称" : bankName,
                        type: cardType.isEmpty ? "卡种" : cardType,
                        endNum: endNum.isEmpty ? "8888" : endNum,
                        colors: [color1, color2] // 实时预览颜色
                    )
                    .listRowInsets(EdgeInsets()) // 去掉两边边距，让卡片撑满
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
                Section(header: Text("返现规则")) {
                    Picker("发行地区", selection: $region) {
                        ForEach(Region.allCases, id: \.self) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }
                    
                    HStack {
                        Text("基础返现率 (%)")
                        Spacer()
                        TextField("1.0", text: $defaultRateStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    
                    HStack {
                        Text("境外返现率 (%)")
                        Spacer()
                        TextField("可选", text: $foreignRateStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                }
                Section(header: Text("特殊返现规则")) {
                    
                    HStack {
                        Text("餐饮返现率 (%)")
                        Spacer()
                        TextField("可选", text: $diningRateStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    
                    HStack {
                        Text("超市返现率 (%)")
                        Spacer()
                        TextField("可选", text: $groceryRateStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    HStack {
                        Text("出行返现率 (%)")
                        Spacer()
                        TextField("可选", text: $travelRateStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    HStack {
                        Text("数码返现率 (%)")
                        Spacer()
                        TextField("可选", text: $digitalRateStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    HStack {
                        Text("其他返现率 (%)")
                        Spacer()
                        TextField("可选", text: $otherRateStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                }
            }
            .navigationTitle("添加信用卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveCard() }
                        .disabled(bankName.isEmpty || cardType.isEmpty || endNum.isEmpty)
                }
            }
        }
    }
    
    func saveCard() {
        // 1. 处理数字 (把 "1.0" 变成 0.01)
        let defaultRate = (Double(defaultRateStr) ?? 0) / 100.0

        var foreignRate: Double = 0
        if !foreignRateStr.isEmpty {
            foreignRate = (Double(foreignRateStr) ?? 0) / 100.0
        }
        
        var diningRate: Double = 0
        if !diningRateStr.isEmpty {
            diningRate = (Double(diningRateStr) ?? 0) / 100.0
        }
        var groceryRate: Double = 0
        if !groceryRateStr.isEmpty {
            groceryRate = (Double(groceryRateStr) ?? 0) / 100.0
        }
        var digitalRate: Double = 0
        if !digitalRateStr.isEmpty {
            digitalRate = (Double(digitalRateStr) ?? 0) / 100.0
        }
        var travelRate: Double = 0
        if !travelRateStr.isEmpty {
            travelRate = (Double(travelRateStr) ?? 0) / 100.0
        }
        var otherRate: Double = 0
        if !otherRateStr.isEmpty {
            otherRate = (Double(otherRateStr) ?? 0) / 100.0
        }
        // 2. 处理颜色 (Color -> Hex String)
        let c1Hex = color1.toHex() ?? "0000FF"
        let c2Hex = color2.toHex() ?? "000000"
        
        // 3. 创建对象
        let newCard = CreditCard(
            bankName: bankName,
            type: cardType,
            endNum: endNum,
            colorHexes: [c1Hex, c2Hex],
            defaultRate: defaultRate,
            specialRates: [.dining:diningRate,
                           .grocery:groceryRate,
                           .digital:digitalRate,
                           .travel:travelRate,
                           .other:otherRate],
            issueRegion: region,
            foreignCurrencyRate: foreignRate
        )
        
        // 4. 存库
        context.insert(newCard)
        // 👇 5. 核心修改：决定怎么关闭页面
        if let onSavedAction = onSaved {
        // 如果有高级指令（比如“关闭所有”），就执行高级指令
            onSavedAction()
        } else {
            // 如果没有（比如是自定义添加），就执行普通的关闭
            dismiss()
        }
    }
}

#Preview {
    AddCardView()
        .modelContainer(for: CreditCard.self, inMemory: true)
}
