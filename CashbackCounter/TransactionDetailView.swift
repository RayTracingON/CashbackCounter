//
//  TransactionDetailView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import SwiftData

struct TransactionDetailView: View {
    let transaction: Transaction
    @Environment(\.dismiss) var dismiss
    
    // 获取计算数据
    var cashback: Double {
        CashbackService.calculateCashback(for: transaction)
    }
    
    var cardName: String {
        CashbackService.getCardName(for: transaction)
    }
    
    var cardNumber: String {
        CashbackService.getCardNum(for: transaction)
    }
    
    var currency: String {
        CashbackService.getCurrency(for: transaction)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // 1. 顶部大图标和商家
                VStack(spacing: 15) {
                    ZStack {
                        Circle()
                            .fill(transaction.category.color.opacity(0.1))
                            .frame(width: 80, height: 80)
                        Image(systemName: transaction.category.iconName)
                            .font(.system(size: 35))
                            .foregroundColor(transaction.category.color)
                    }
                    
                    Text(transaction.merchant)
                        .font(.title2)
                        .fontWeight(.bold)
                }
                .padding(.top, 40)
                
                // 2. 金额显示
                Text("- \(currency)\(String(format: "%.2f", transaction.amount))")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                
                // 3. 详细信息列表
                VStack(spacing: 0) {
                    DetailRow(title: "交易时间", value: transaction.dateString) // 这里的 dateString 如果不够详细，可以用 formatter 再转一次
                    Divider()
                    DetailRow(title: "支付卡片", value: cardName)
                    Divider()
                    DetailRow(title: "卡片尾号", value: cardNumber)
                    Divider()
                    DetailRow(title: "消费类别", value: transaction.category.displayName)
                    Divider()
                    DetailRow(title: "消费地区", value: "\(transaction.location.icon) \(transaction.location.rawValue)")
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                
                // 4. 返现高亮区域
                if cashback > 0 {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("本单返现")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text("\(currency)\(String(format: "%.2f", cashback))")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.green)
                        }
                        Spacer()
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                            .foregroundColor(.green.opacity(0.3))
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
                if let data = transaction.receiptData,
                                   let uiImage = UIImage(data: data) {
                                    
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("电子收据")
                                            .font(.headline)
                                            .foregroundColor(.secondary)
                                        
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxHeight: 300) // 限制最大高度，防止太长
                                            .cornerRadius(12)
                                            .onTapGesture {
                                                // 这里以后可以做“点击查看大图”的功能
                                            }
                                    }
                                    .padding()
                                }
                Spacer()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// 辅助子视图：一行详情
struct DetailRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title).foregroundColor(.gray)
            Spacer()
            Text(value)
        }
        .padding()
    }
}
