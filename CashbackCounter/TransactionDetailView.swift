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
    @State private var showFullImage = false
    
    // 获取计算数据
    var cashback: Double {
        transaction.cashbackamount
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
    var billamount: Double {
        transaction.billingAmount
    }
    var cardregion: String {
        transaction.card?.issueRegion.currencySymbol ?? ""
    }
    var cashbackrate: String {
        String(format: "%.1f", transaction.rate*100)
    }
    
    var body: some View {
        NavigationView {
            ScrollView{
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
                        DetailRow(title: "入账金额", value: (cardregion+String(format: "%.2f", billamount)))
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
                                Text("\(cardregion)\(String(format: "%.2f", cashback))"+"(\(cashbackrate)%)")
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
                    // 👇 5. 电子收据区域 (优化版)
                    if let data = transaction.receiptData,
                       let uiImage = UIImage(data: data) {
                        
                        VStack(spacing: 15) {
                            // 分割线
                            Divider()
                            
                            HStack {
                                Text("电子收据")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 300)
                                .cornerRadius(12)
                                .shadow(radius: 5)
                            // 👇 点击触发全屏
                                .onTapGesture {
                                    showFullImage = true
                                }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 30)
                        // 👇 全屏覆盖层绑定
                        .sheet(isPresented: $showFullImage){
                            ReceiptFullScreenView(image: uiImage)
                                // 可选：显示下拉指示条，提示用户可以下拉
                                .presentationDragIndicator(.visible)
                        }
                    }
                }
                .padding(.vertical)
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
