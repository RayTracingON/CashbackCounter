import SwiftUI

struct MonthYearPicker: View {
    @Binding var date: Date
    @Binding var isWholeYear: Bool // 👈 新增：告诉父视图是不是选了全年
    @Environment(\.dismiss) var dismiss
    
    // 年份范围
    private let years: [Int] = Array((Calendar.current.component(.year, from: Date()) - 10)...(Calendar.current.component(.year, from: Date())))
    
    // 月份范围：0 代表 "全年"，1-12 代表月份
    private let months: [Int] = Array(0...12)
    
    @State private var selectedYear: Int
    @State private var selectedMonth: Int
    
    init(date: Binding<Date>, isWholeYear: Binding<Bool>) {
        self._date = date
        self._isWholeYear = isWholeYear
        
        let calendar = Calendar.current
        _selectedYear = State(initialValue: calendar.component(.year, from: date.wrappedValue))
        
        // 如果是全年的话，滚轮停在 0；否则停在当前月份
        if isWholeYear.wrappedValue {
            _selectedMonth = State(initialValue: 0)
        } else {
            _selectedMonth = State(initialValue: calendar.component(.month, from: date.wrappedValue))
        }
    }
    
    var body: some View {
        VStack {
            // 顶部工具栏
            HStack {
                Button("取消") { dismiss() }
                    .foregroundColor(.secondary)
                Spacer()
                Text("选择时间").font(.headline)
                Spacer()
                Button("确定") {
                    saveSelection()
                    dismiss()
                }
                .fontWeight(.bold)
            }
            .padding()
            .background(Color(uiColor: .systemGray6))
            
            // 滚轮区域
            HStack {
                // 年份
                Picker("Year", selection: $selectedYear) {
                    ForEach(years, id: \.self) { year in
                        Text(String(format: "%d年", year)).tag(year)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                
                // 月份 (0是全年)
                Picker("Month", selection: $selectedMonth) {
                    ForEach(months, id: \.self) { month in
                        if month == 0 {
                            Text("全年").tag(0) // 👈 特殊选项
                        } else {
                            Text(String(format: "%d月", month)).tag(month)
                        }
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .presentationDetents([.height(300)])
    }
    
    func saveSelection() {
        var components = DateComponents()
        components.year = selectedYear
        
        if selectedMonth == 0 {
            // 选择了全年
            isWholeYear = true
            // 日期设为该年1月1日，方便后续处理
            components.month = 1
            components.day = 1
        } else {
            // 选择了具体月份
            isWholeYear = false
            components.month = selectedMonth
            components.day = 1
        }
        
        if let newDate = Calendar.current.date(from: components) {
            date = newDate
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("年月选择器 · 选某月") {
    @Previewable @State var date = Date()
    @Previewable @State var isWholeYear = false
    MonthYearPicker(date: $date, isWholeYear: $isWholeYear)
}

#Preview("年月选择器 · 全年") {
    // isWholeYear = true 时月份滚轮应停在"全年"（内部用 0 表示）
    @Previewable @State var date = Date()
    @Previewable @State var isWholeYear = true
    MonthYearPicker(date: $date, isWholeYear: $isWholeYear)
}
#endif
