import SwiftUI

struct IncomeRow: View {
    let income: Income
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(income.currencyCode) \(String(format: \"%.2f\", income.amount))")
                    .font(.subheadline).fontWeight(.semibold)
                Text(income.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.down.backward.and.arrow.up.forward")
                .foregroundColor(.green)
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
}
