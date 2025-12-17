//
//  TransactionRow.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI

struct TransactionRow: View {
    let transaction: Transaction
    var exchangeRates: [String: Double] = [:]
    @AppStorage("mainCurrencyCode") private var mainCurrencyCode: String = "CNY"

    private var incomeDisplayText: String? {
        guard
            let incomes = transaction.incomes,
            !incomes.isEmpty,
            let expense = convertToMainCurrency(
                amount: transaction.billingAmount,
                currencyCode: transaction.card?.issueRegion.currencyCode ?? mainCurrencyCode
            )
        else { return nil }

        let totalIncome = incomes
            .compactMap { convertToMainCurrency(amount: $0.amount, currencyCode: $0.location.currencyCode) }
            .reduce(0, +)

        guard totalIncome > expense else { return nil }
        return (totalIncome-expense).formatted(.currency(code: mainCurrencyCode))
    }

    private func convertToMainCurrency(amount: Double, currencyCode: String) -> Double? {
        if currencyCode == mainCurrencyCode { return amount }
        guard let rate = exchangeRates[currencyCode], rate != 0 else { return nil }
        return amount / rate
    }

    var body: some View {
        HStack(spacing: 12) {
            // 1. 左侧图标
            ZStack {
                Circle()
                    .fill(transaction.category.color.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                Image(systemName: transaction.category.iconName)
                    .font(.system(size: 20))
                    .foregroundColor(transaction.category.color)
            }
            
            // 2. 中间信息 (商户名 + 卡片名)
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchant)
                    .font(.headline)
                
                // ✨ 关键修改：显示卡片全称，允许换行
                if let card = transaction.card {
                    Text(card.bankName + " " + card.type)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true) // 允许垂直方向换行
                        .lineLimit(2) // 最多显示2行，防止太长
                }
            }
            
            Spacer() // ✨ 关键修改：用 Spacer 撑开，保证右边对齐
            
            // 3. 右侧金额
            VStack(alignment: .trailing, spacing: 4) {
                // 消费金额
                Text("\(transaction.location.currencyCode) \(String(format: "%.2f", transaction.amount))")
                    .fontWeight(.bold)

                if let incomeText = incomeDisplayText {
                    Text("收入 \(incomeText)")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                // 日期
                HStack(spacing: 2) {
                    // 显示交易日期
                    Text(transaction.dateString)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

