import SwiftUI
import SwiftData

struct IncomeRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var income: Income
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleReceived) {
                Image(systemName: income.isReceived ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(income.isReceived ? .green : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(income.detail)
                    .font(.headline)
                
                Text(income.platform+"交易")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(income.location.currencyCode) \(income.amount, format: .number.precision(.fractionLength(2)))")
                    .fontWeight(.bold)
                Text(income.dateString)
                    .font(.caption)
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(10)
    }

    private func toggleReceived() {
        income.isReceived.toggle()
        try? context.save()
    }
}
