//
//  PointSystemViewModel.swift
//  CashbackCounter
//

import SwiftUI
import SwiftData

// MARK: - Point Program Summary (shared with PointDetailView)

struct PointProgramSummary: Identifiable {
    let id: String
    let program: Point?
    let bankName: String
    let pointName: String
    let points: Int
    let themeColors: [Color]
}

// MARK: - ViewModel

@Observable
final class PointSystemViewModel {
    // MARK: - State
    var exchangeRates: [String: Double] = [:]
    var showPointLibrary = false
    var showPointAdjustment = false
    var showPointRemoval = false

    // MARK: - Computed Helpers

    var isRatesReady: Bool {
        !exchangeRates.isEmpty
    }

    var fallbackColors: [Color] {
        [Color.gray.opacity(0.35), Color.gray.opacity(0.15)]
    }

    // MARK: - Data Aggregation

    func pointSummaries(transactions: [Transaction], adjustments: [PointAdjustment], cards: [CreditCard]) -> [PointProgramSummary] {
        var totals: [String: Int] = [:]
        var programs: [String: Point?] = [:]

        for transaction in transactions {
            let points = transaction.pointsEarned
            guard points != 0 else { continue }

            if let program = transaction.card?.pointProgram {
                let key = program.id.uuidString
                totals[key, default: 0] += points
                programs[key] = program
            } else {
                let key = "unassigned"
                totals[key, default: 0] += points
                programs[key] = nil
            }
        }

        for adjustment in adjustments {
            guard adjustment.points != 0 else { continue }
            guard let program = adjustment.pointProgram else { continue }
            let key = program.id.uuidString
            totals[key, default: 0] += adjustment.points
            programs[key] = program
        }

        let pointCards = cards.filter { $0.rewardType == .points }
        for card in pointCards {
            if let program = card.pointProgram {
                let key = program.id.uuidString
                if totals[key] == nil {
                    totals[key] = 0
                    programs[key] = program
                }
            }
        }

        guard !totals.isEmpty else { return [] }

        let cardMap = Dictionary(grouping: pointCards, by: { $0.pointProgram?.id.uuidString ?? "unassigned" })

        return totals.map { key, points in
            let program = programs[key] ?? nil
            let card = cardMap[key]?.first
            let colors = (card?.colors.count ?? 0) >= 2 ? (card?.colors ?? fallbackColors) : fallbackColors
            let bankName = program?.bankName ?? "未分配"
            let pointName = program?.pointName ?? "积分计划"

            return PointProgramSummary(
                id: key,
                program: program,
                bankName: bankName,
                pointName: pointName,
                points: points,
                themeColors: colors
            )
        }
        .sorted { $0.points > $1.points }
    }

    // MARK: - Value Estimation

    func estimatedValue(for summary: PointProgramSummary, mainCurrencyCode: String) -> Double {
        guard let program = summary.program, summary.points > 0 else { return 0 }
        let value = Double(summary.points) * program.pointValue
        return convertToMainCurrency(value, from: program.valueCurrencyCode.currencyCode, mainCurrencyCode: mainCurrencyCode)
    }

    func totalEstimatedValue(for summaries: [PointProgramSummary], mainCurrencyCode: String) -> Double {
        summaries.reduce(0) { partial, summary in
            partial + estimatedValue(for: summary, mainCurrencyCode: mainCurrencyCode)
        }
    }

    // MARK: - Currency Conversion

    func convertToMainCurrency(_ amount: Double, from currencyCode: String, mainCurrencyCode: String) -> Double {
        guard currencyCode != mainCurrencyCode else { return amount }
        guard let rate = rateForCurrency(currencyCode), rate > 0 else { return amount }
        return amount / rate
    }

    func rateForCurrency(_ code: String) -> Double? {
        exchangeRates[code.lowercased()] ?? exchangeRates[code]
    }

    func normalizeRates(_ rates: [String: Double]) -> [String: Double] {
        Dictionary(rates.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, new in new })
    }

    // MARK: - Formatting

    func formattedPoints(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = AppLanguage.locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    func formattedCurrency(_ value: Double, code: String) -> String {
        value.formatted(.currency(code: code).locale(AppLanguage.locale))
    }

    // MARK: - Data Loading

    func refreshRates(mainCurrencyCode: String) async {
        let rates = await CurrencyService.getRates(base: mainCurrencyCode)
        await MainActor.run {
            exchangeRates = normalizeRates(rates)
        }
    }
}
