//
//  TransactionRow.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI

struct TransactionRow: View {
    let transaction: Transaction
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 15) {
            // 图标部分 (保持不变)
            ZStack {
                Circle()
                    .fill(transaction.category.color.opacity(0.1))
                    .frame(width: 50, height: 50)
                Image(systemName: transaction.category.iconName)
                    .font(.title3)
                    .foregroundColor(transaction.category.color)
            }
            
            // --- 左边：商家 + (日期 & 卡片) ---
            VStack(alignment: .leading, spacing: 4) {
                            Text(transaction.merchant).font(.headline)
                            
                            // 👇 修改：调用 Service，传入 transaction 和 manager.cards
                            let cardName = CashbackService.getCardName(for: transaction)
                            Text("\(transaction.dateString) · \(cardName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
            
            Spacer()
            
            // --- 右边：金额 + (返现金额 & 比例) ---
            VStack(alignment: .trailing, spacing: 4) {
                let symbol = CashbackService.getCurrency(for: transaction)
                Text("- \(symbol)\(String(format: "%.2f", transaction.amount))")
                                    .font(.system(.body, design: .rounded))
                                    .fontWeight(.semibold)
                                
                // 3. 显示返现
                let cashback = transaction.cashbackamount
                                
                if cashback > 0 {
                    HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 10))
                                        
                    let rate = CashbackService.getRate(for: transaction)
                    Text("返 \((rate * 100).formatted(.number.precision(.fractionLength(1))))%")
                            .font(.system(size: 10, weight: .medium))
                            .opacity(0.8)
                                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.1))
                    .foregroundColor(.green)
                    .cornerRadius(4)
                }
            }
        }
        .padding()
        // ... 背景和阴影代码保持不变 ...
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(15)
        .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.02), radius: 5, x: 0, y: 2)
    }
}
