import SwiftUI

struct IncomeRow: View {
    let income: Income
    
    var body: some View {
        HStack {
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
}
