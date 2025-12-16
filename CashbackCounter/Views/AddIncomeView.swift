import SwiftUI
import SwiftData

struct AddIncomeView: View {
    let transaction: Transaction
    
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    
    @State private var amount: String = ""
    @State private var detail: String = ""
    @State private var platform: String = ""
    @State private var location: Region
    @State private var date: Date = Date()
    
    
    init(transaction: Transaction) {
        self.transaction = transaction
        location = transaction.location
        _date = State(initialValue: Date())
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("收入信息")) {
                    TextField("交易内容", text: $detail)
                    
                    TextField("交易平台", text: $platform)
                    
                    TextField("收入金额", text: $amount)
                        .keyboardType(.decimalPad)
                    
                    Picker("收入地区", selection: $location) {
                        ForEach(Region.allCases, id: \.self) { r in
                            Text("\(r.icon) \(r.rawValue)").tag(r)
                        }
                    }
                    
                    DatePicker("入账日期", selection: $date, in: ...Date(), displayedComponents: .date)
                }
                
                Section {
                    HStack {
                        Text("关联交易")
                        Spacer()
                        Text(transaction.merchant)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("消费日期")
                        Spacer()
                        Text(transaction.dateString)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("添加收入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveIncome() }
                        .disabled(!canSave)
                }
            }
        }
    }
    
    private var canSave: Bool {
        let trimmed = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed) else { return false }
        return value > 0
    }
    
    private func saveIncome() {
        guard let amt = Double(amount) else { return }
        let income = Income(amount: amt, date: date, location: location, transaction: transaction, detail: detail, platform: platform)
        context.insert(income)
        dismiss()
    }
}
