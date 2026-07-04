//
//  TransactionDetailView.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/25/25.
//

import SwiftUI
import SwiftData

struct TransactionDetailView: View {
    @Environment(\.dismiss) var dismiss
    @Bindable var transaction: Transaction
    
    @State private var showEditSheet = false
    @State private var showFullScreenReceipt = false
    
    // 格式化日期
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }
    
    var body: some View {
        NavigationStack {
            List {
                // MARK: - 1. 顶部 Header (紧凑版)
                Section {
                    VStack(spacing: 8) { // 减小垂直间距
                        // 第一行：图标 + 商户名
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                    .frame(width: 50, height: 50) // 缩小尺寸 80 -> 50
                                    .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
                                
                                Image(systemName: transaction.category.iconName)
                                    .font(.system(size: 24))
                                    .foregroundColor(transaction.category.color) // 使用分类原本颜色
                            }
                            
                            Text(transaction.merchant)
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        }
                        
                        // 第二行：大金额
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(transaction.location.currencyCode)
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .offset(y: -4) // 稍微上移，让主金额更突出
                            
                            Text(String(format: "%.2f", transaction.amount))
                                .font(.system(size: 44, weight: .bold, design: .rounded)) // 稍微加大金额，但整体高度变小
                                .foregroundColor(.primary)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10) // 减少上下留白
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                
                // MARK: - 2. 交易信息
                Section("基本信息") {
                    DetailRow(title: "交易时间", value: dateFormatter.string(from: transaction.date), icon: "calendar")
                    DetailRow(title: "消费类别", value: transaction.category.displayName, icon: "tag")
                    DetailRow(title: "消费地区", value: transaction.location.rawValue, icon: "mappin.and.ellipse")
                }
                
                // MARK: - 3. 支付详情
                Section("支付详情") {
                    // 支付方式
                    HStack {
                        Label {
                            Text("支付方式")
                        } icon: {
                            Image(systemName: "iphone.gen3")
                                .foregroundColor(.purple)
                        }
                        Spacer()
                        
                        // 胶囊样式的支付方式
                        HStack(spacing: 6) {
                            Image(systemName: transaction.paymentMethod.iconName)
                                .font(.caption)
                            Text(transaction.paymentMethod.displayName)
                                .font(.subheadline)
                        }
                        .foregroundColor(transaction.paymentMethod.color)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(transaction.paymentMethod.color.opacity(0.1))
                        .cornerRadius(DesignConstants.CornerRadius.small)
                    }
                    
                    // 支付卡片
                    if let card = transaction.card {
                        HStack {
                            Label("支付卡片", systemImage: "creditcard")
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: card.colors,
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 12, height: 12)
                                
                                Text("\(card.bankName) \(card.type)")
                                    .foregroundColor(.secondary)
                                Text("(\(card.endNum))")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    } else {
                        DetailRow(title: "支付卡片", value: "无卡/现金", icon: "creditcard")
                    }
                    
                    // 入账金额 (如果有汇率差)
                    if transaction.amount != transaction.billingAmount && transaction.amount > 0 {
                        HStack {
                            Label("入账金额", systemImage: "banknote")
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(String(format: "%.2f %@", transaction.billingAmount, transaction.card != nil ? transaction.resolvedBillingCurrencyCode : "CNY"))
                                let rate = transaction.billingAmount / transaction.amount
                                Text("汇率约 \(String(format: "%.4f", rate))")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
                
                // MARK: - 4. 返现分析
                Section("返现分析") {
                    let isPoints = transaction.card?.rewardType == .points
                    let rewardCurrency = transaction.card != nil ? transaction.resolvedBillingCurrencyCode : "CNY"
                    
                    HStack {
                        Label {
                            Text(isPoints ? "预计积分价值" : "预计返现")
                        } icon: {
                            Image(systemName: "sparkles")
                                .foregroundColor(.yellow)
                        }
                        Spacer()
                        Text("+\(transaction.cashbackamount.formatted(.currency(code: rewardCurrency)))")
                            .font(.headline)
                            .foregroundColor(.green)
                    }
                    
                    if isPoints {
                        DetailRow(title: "积分数", value: String(transaction.pointsEarned), icon: "star.circle")
                    }
                    
                    if transaction.billingAmount > 0 {
                        let actualRate = (transaction.cashbackamount / transaction.billingAmount) * 100
                        DetailRow(title: "实际回馈率", value: String(format: "%.2f%%", actualRate), icon: "percent")
                    }
                }
                
                // MARK: - 5. 凭证与关联
                Section("凭证") {
                    if let data = transaction.receiptData, let uiImage = UIImage(data: data) {
                        Button {
                            showFullScreenReceipt = true
                        } label: {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 160) // 稍微改小一点高度，节省空间
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .listRowInsets(EdgeInsets())
                        }
                    } else {
                        HStack {
                            Image(systemName: "doc.text.image")
                                .foregroundColor(.gray)
                            Text("无收据图片")
                                .foregroundColor(.gray)
                        }
                    }
                }
                
                // 关联收入
                if let incomes = transaction.incomes, !incomes.isEmpty {
                    Section("已抵扣/关联收入") {
                        ForEach(incomes) { income in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(income.platform)
                                        .font(.subheadline)
                                    Text(income.dateString)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Text("-\(String(format: "%.2f", income.amount))")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
                
                // 删除按钮
                Section {
                    Button(role: .destructive) {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            transaction.modelContext?.delete(transaction)
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text("删除此交易")
                            Spacer()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("交易详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 1. 左上角关闭按钮
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(.secondary)
                            .font(.title2)
                    }
                }
                
                // 2. 右上角编辑按钮
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") {
                        showEditSheet = true
                    }
                }
            }
            .sheet(isPresented: $showEditSheet) {
                AddTransactionView(transaction: transaction)
            }
            .sheet(isPresented: $showFullScreenReceipt) {
                if let data = transaction.receiptData,
                   let image = UIImage(data: data) {
                    ReceiptFullScreenView(image: image)
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }
}

// 辅助视图
struct DetailRow: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}
