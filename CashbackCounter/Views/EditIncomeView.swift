import SwiftUI
import SwiftData

struct EditIncomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var income: Income

    @State private var amount: String
    @State private var detail: String
    @State private var platform: String
    @State private var location: Region
    @State private var date: Date

    init(income: Income) {
        self.income = income
        _amount = State(initialValue: String(format: "%.2f", income.amount))
        _detail = State(initialValue: income.detail)
        _platform = State(initialValue: income.platform)
        _location = State(initialValue: income.location)
        _date = State(initialValue: income.date)
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
                        Text(income.transaction?.merchant ?? "-")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("消费日期")
                        Spacer()
                        Text(income.transaction?.dateString ?? "-")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("编辑收入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveChanges() }
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

    private func saveChanges() {
        guard let amt = Double(amount.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        income.amount = amt
        income.detail = detail
        income.platform = platform
        income.location = location
        income.date = date
        try? context.save()
        dismiss()
    }
}

