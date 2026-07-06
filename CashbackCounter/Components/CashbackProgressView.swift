//
//  CashbackProgressView.swift
//  CashbackCounter
//
//  卡片返现/积分计划进度条 — 显示当前结算周期内各计划的使用进度。
//  有上限的计划显示进度条；无上限的计划显示累计金额。
//

import SwiftUI

// MARK: - 进度数据模型

/// 单条返现（或积分）计划的使用进度
struct CashbackCapProgress: Identifiable {
    let id: String
    let title: String
    let iconName: String
    let color: Color
    /// 当前周期内已使用的返现/积分
    let used: Double
    /// 该周期的上限（<= 0 表示无上限）
    let limit: Double
    /// 该计划的计价货币符号；nil = 用卡片主币种（陆式双币卡的外币轨道以副币种计价）
    var currencySymbolOverride: String? = nil

    /// 是否无上限
    var isUnlimited: Bool { limit <= 0 }

    /// 已用比例（0...1），无上限时无意义
    var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(1.0, max(0, used / limit))
    }

    /// 是否已达上限
    var isMaxedOut: Bool { !isUnlimited && fraction >= 1.0 }
}

// MARK: - 进度计算

extension CreditCard {

    /// 计算当前结算周期内，各项返现/积分计划的使用进度。
    /// 包含有上限与无上限的计划（只要该计划有对应费率或上限即会显示）。
    func cashbackCapProgress(asOf date: Date = Date()) -> [CashbackCapProgress] {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: date)
        let currentMonth = calendar.component(.month, from: date)

        // 筛选当前结算周期内的交易
        let periodTransactions = (transactions ?? []).filter { t in
            guard calendar.component(.year, from: t.date) == currentYear else { return false }
            switch capPeriod {
            case .yearly:
                return true
            case .monthly:
                return calendar.component(.month, from: t.date) == currentMonth
            }
        }

        var results: [CashbackCapProgress] = []

        // A. 本币基础返现计划（有基础费率或设置了上限则显示）
        // 港式双币卡：副币入账消费也在本币轨道，账单金额按 1:1 计入
        if defaultRate > 0 || localBaseCap > 0 {
            let used = periodTransactions
                .filter { rewardTrack(for: $0.location) == .local }
                .reduce(0.0) { $0 + ($1.billingAmount * baseRate(forLocation: $1.location)) }
            results.append(CashbackCapProgress(
                id: "base_local",
                title: rewardType == .points
                    ? String(localized: "本地基础积分")
                    : String(localized: "本地基础返现"),
                iconName: "creditcard.fill",
                color: .blue,
                used: used,
                limit: localBaseCap
            ))
        }

        // B. 外币基础返现计划（有境外费率或设置了上限则显示）
        // 陆式双币卡：境外消费一律入账副币种，上限与用量均以副币种计价，符号随之切换
        let foreignRate = foreignCurrencyRate ?? 0
        if foreignRate > 0 || foreignBaseCap > 0 {
            let foreignTrackSymbol: String? = (isDualCurrency && dualCurrencyMode == .secondaryAsForeign)
                ? secondaryRegion?.currencySymbol
                : nil
            let used = periodTransactions
                .filter { rewardTrack(for: $0.location) == .foreign }
                .reduce(0.0) { $0 + ($1.billingAmount * baseRate(forLocation: $1.location)) }
            results.append(CashbackCapProgress(
                id: "base_foreign",
                title: rewardType == .points
                    ? String(localized: "境外基础积分")
                    : String(localized: "境外基础返现"),
                iconName: "airplane",
                color: .teal,
                used: used,
                limit: foreignBaseCap,
                currencySymbolOverride: foreignTrackSymbol
            ))
        }

        // C. 类别加成计划（有加成费率或设置了上限则显示）
        for category in Category.allCases {
            let bonusRate = specialRates[category] ?? 0.0
            let cap = categoryCaps[category] ?? 0.0
            guard bonusRate > 0 || cap > 0 else { continue }
            let used = periodTransactions
                .filter { $0.category == category }
                .reduce(0.0) { $0 + ($1.billingAmount * bonusRate) }
            results.append(CashbackCapProgress(
                id: "cat_\(category.rawValue)",
                title: category.displayName,
                iconName: category.iconName,
                color: category.color,
                used: used,
                limit: cap
            ))
        }

        // D. 支付方式加成计划（有加成费率或设置了上限则显示）
        for method in PaymentMethod.allCases {
            let bonusRate = paymentMethodRates[method] ?? 0.0
            let cap = paymentCaps[method] ?? 0.0
            guard bonusRate > 0 || cap > 0 else { continue }
            let used = periodTransactions
                .filter { $0.paymentMethod == method }
                .reduce(0.0) { $0 + ($1.billingAmount * bonusRate) }
            results.append(CashbackCapProgress(
                id: "pay_\(method.rawValue)",
                title: method.displayName,
                iconName: method.iconName,
                color: method.color,
                used: used,
                limit: cap
            ))
        }

        return results
    }
}

// MARK: - 进度条视图

/// 单条进度条
struct CashbackProgressRow: View {
    let item: CashbackCapProgress
    /// 用于格式化数值的前缀（货币符号）或后缀（积分单位）
    let isPoints: Bool
    let currencySymbol: String

    private func formatted(_ value: Double) -> String {
        let rounded = String(format: "%.0f", value)
        return isPoints ? String(localized: "\(rounded)分") : "\(currencySymbol)\(rounded)"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(item.color)
                    .frame(width: 18)

                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if item.isUnlimited {
                    Text("\(formatted(item.used)) · 无上限")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                } else {
                    Text("\(formatted(item.used)) / \(formatted(item.limit))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(item.isMaxedOut ? item.color : .secondary)
                        .monospacedDigit()
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(uiColor: .tertiarySystemFill))

                    if item.isUnlimited {
                        // 无上限：显示整条淡色渐变，表示持续累计、无封顶
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [item.color.opacity(0.35), item.color.opacity(0.15)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    } else {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [item.color.opacity(0.65), item.color],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * item.fraction))
                    }
                }
            }
            .frame(height: 8)
        }
    }
}

/// 进度条区块（卡片图片与交易列表之间显示）
struct CashbackProgressSection: View {
    let card: CreditCard

    private var items: [CashbackCapProgress] {
        card.cashbackCapProgress()
    }

    private var headerTitle: String {
        switch (card.capPeriod, card.rewardType) {
        case (.monthly, .points):   return String(localized: "本月积分进度")
        case (.monthly, .cashback): return String(localized: "本月返现进度")
        case (.yearly, .points):    return String(localized: "本年积分进度")
        case (.yearly, .cashback):  return String(localized: "本年返现进度")
        }
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(headerTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                }

                ForEach(items) { item in
                    CashbackProgressRow(
                        item: item,
                        isPoints: card.rewardType == .points,
                        currencySymbol: item.currencySymbolOverride ?? card.issueRegion.currencySymbol
                    )
                }
            }
            .padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .cornerRadius(DesignConstants.CornerRadius.large)
            .padding(.horizontal, 16)
        }
    }
}
