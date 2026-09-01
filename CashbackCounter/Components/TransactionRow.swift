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

    // MARK: - 计算逻辑
    
    // 1. 计算净收益文本（如果 报销/回血 > 支出）
    private var netIncomeText: String? {
        guard
            let incomes = transaction.incomes,
            !incomes.isEmpty,
            let expense = convertToMainCurrency(
                amount: transaction.billingAmount,
                currencyCode: transaction.resolvedBillingCurrencyCode
            )
        else { return nil }

        let totalIncome = incomes
            .compactMap { convertToMainCurrency(amount: $0.amount, currencyCode: $0.location.currencyCode) }
            .reduce(0, +)

        guard totalIncome > expense else { return nil }
        return (totalIncome - expense).formatted(.currency(code: mainCurrencyCode))
    }
    
    // 2. 计算标准返现文本
    private var cashbackText: String {
        let billingCurrency = transaction.resolvedBillingCurrencyCode
        // 换不了汇（汇率没传进来 / 缺这个币种）时按入账币种原样显示。
        // 拿原币数字套本币符号是在报一个不存在的金额，比多一个币种符号糟得多。
        guard let amount = convertToMainCurrency(amount: transaction.cashbackamount, currencyCode: billingCurrency) else {
            return transaction.cashbackamount.formatted(.currency(code: billingCurrency))
        }
        return amount.formatted(.currency(code: mainCurrencyCode))
    }

    private func convertToMainCurrency(amount: Double, currencyCode: String) -> Double? {
        if currencyCode == mainCurrencyCode { return amount }
        let rate = exchangeRates[currencyCode]
            ?? exchangeRates[currencyCode.uppercased()]
            ?? exchangeRates[currencyCode.lowercased()]
        guard let rate, rate != 0 else { return nil }
        return amount / rate
    }

    // MARK: - View Body
    var body: some View {
        HStack(spacing: 10) {
            // 1. 左侧图标
            ZStack {
                Circle()
                    .fill(transaction.category.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                
                Image(systemName: transaction.category.iconName)
                    .font(.system(size: 20))
                    .foregroundColor(transaction.category.color)
            }
            
            // 2. 中间信息
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchant)
                    .font(.system(size: 16, weight: .medium)) // 稍微调整字号
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                if let card = transaction.card {
                    Text(card.bankName + " " + card.type)
                    
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                } else {
                     // 占位，保持视觉重心一致（可选）
                     Text(" ")
                        .font(.caption)
                }
            }
            
            Spacer()
            
            // 3. 右侧信息 (金额 + 收益 + 日期)
            VStack(alignment: .trailing, spacing: 0) {
                // A. 消费金额
                Text("\(transaction.location.currencyCode) \(String(format: "%.2f", transaction.amount))")
                    .font(.system(size: 16, weight: .bold)) // 与左侧商户名平衡
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    // 向下加一点点 padding 给中间的返现腾出呼吸感
                    .padding(.bottom, 2)

                // B. 收益/返现显示区 (固定高度区域，防止跳动)
                Group {
                    if let income = netIncomeText {
                        // 赚钱了
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up.right.circle.fill")
                                .font(.system(size: 10))
                            Text("赚 \(income)")
                        }
                        .foregroundColor(.green)
                    } else if transaction.cashbackamount > 0 {
                        // 普通返现
                        let isPoints = transaction.card?.rewardType == .points
                        HStack(spacing: 2) {
                            Image(systemName: isPoints ? "star.circle.fill" : "arrow.uturn.backward.circle.fill")
                                .font(.system(size: 10))
                            Text("\(isPoints ? "值" : "返") \(cashbackText)")
                        }
                        .foregroundColor(isPoints ? .blue : .orange)
                    } else {
                        // 占位符：如果是 0 返现，显示透明文字或者高度为0
                        // 为了保持绝对对齐，建议用 Text(" ").frame(height: 14) 占位
                        // 这里选择不显示，让日期自然靠拢，避免空白太大
                        EmptyView()
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .frame(height: 16) // 固定这一行的高度，有内容就显示，没内容就空着但占位?
                // 修正：如果这里强制占位，没返现时会有一行空白。
                // 建议：不强制 frame，让它自然消失。但如果你想要“金额”在所有行都绝对处于同一水平线，就需要强制占位。
                // 这里我选择不强制占位，因为视觉上紧凑更重要。
                
                // C. 日期 (放在最下面)
                Text(transaction.dateString)
                    .font(.system(size: 10)) // 极小字体，类似页脚
                    .foregroundColor(.tertiaryLabel) // 很淡的颜色，不抢戏
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 72) // 强制高度
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// 辅助扩展：为了兼容 .tertiaryLabel (iOS 13+ UIColor)
extension Color {
    static let tertiaryLabel = Color(uiColor: .tertiaryLabel)
}
