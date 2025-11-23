//
//  TransactionRow.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI

struct TransactionRow: View {
    let transaction: Transaction
    
    // 1. 安装传感器
    @Environment(\.colorScheme) var colorScheme
    // 需要用到 manager 来计算金额
    @EnvironmentObject var manager: DataManager
    
    var body: some View {
            HStack(spacing: 15) {
                ZStack {
                    // 👇 颜色改用 Category 里的颜色
                    Circle()
                        .fill(transaction.category.color.opacity(0.1))
                        .frame(width: 50, height: 50)
                    // 👇 图标改用 Category 里的图标
                    Image(systemName: transaction.category.iconName)
                        .font(.title3)
                        .foregroundColor(transaction.category.color)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(transaction.merchant).font(.headline)
                    Text(transaction.dateString).font(.caption).foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("- \(String(format: "%.2f", transaction.amount))")
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.semibold)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.system(size: 10))
                        
                        // 👇👇👇 核心修改：调用 manager.getCashback
                        let cashback = manager.getCashback(for: transaction)
                        Text("返 ¥\(String(format: "%.2f", cashback))")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.1))
                    .foregroundColor(.green)
                    .cornerRadius(4)
                }
            }
        .padding()
        // 2. 背景色升级
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(15)
        // 3. 阴影处理
        .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.02), radius: 5, x: 0, y: 2)
        // 4. 深色模式专属描边
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.gray.opacity(0.2), lineWidth: colorScheme == .dark ? 0.5 : 0)
        )
    }
}
