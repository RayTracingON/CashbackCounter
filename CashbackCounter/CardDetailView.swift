//
//  CardDetailView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/26/25.
//

import SwiftUI
import SwiftData

struct CardDetailView: View {
    @Environment(\.dismiss) var dismiss
    
    // 接收外部传入的卡片
    let card: CreditCard
    
    // 按日期倒序排列交易
    var sortedTransactions: [Transaction] {
        (card.transactions ?? []).sorted { $0.date > $1.date }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // 背景色：使用分组背景，更有层次感
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // --- 1. 顶部卡片大图 ---
                        // 这里不需要太多 padding，让它大一点，更有视觉冲击力
                        VStack {
                            CreditCardView(
                                bankName: card.bankName,
                                type: card.type,
                                endNum: card.endNum,
                                colors: card.colors
                            )
                            .frame(height: 220) // 稍微加大高度
                            .shadow(color: .black.opacity(0.15), radius: 15, x: 0, y: 5) // 加深阴影，营造悬浮感
                        }
                        .padding(.top, 20)
                        
                        // --- 2. 交易列表区域 ---
                        VStack(alignment: .leading, spacing: 0) {
                            
                            // 列表标题
                            Text("最新交易")
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.leading, 16)
                                .padding(.bottom, 8)
                            
                            if sortedTransactions.isEmpty {
                                // 空状态
                                VStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 40))
                                        .foregroundColor(.gray.opacity(0.4))
                                    Text("此卡片暂无交易记录")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                                .cornerRadius(12)
                                .padding(.horizontal, 16)
                                
                            } else {
                                // 交易列表容器
                                LazyVStack(spacing: 0) {
                                    ForEach(sortedTransactions) { transaction in
                                        VStack(spacing: 0) {
                                            // 复用你已有的 TransactionRow 组件
                                            TransactionRow(transaction: transaction)
                                                .padding(.vertical, 8)
                                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                                        }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12)) // 整个列表切圆角
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.bottom, 30) // 底部留白
                }
            }
            // 导航栏设置
            .navigationTitle(card.bankName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 右上角关闭按钮
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.gray.opacity(0.8))
                    }
                }
            }
        }
    }
}
