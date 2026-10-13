import Foundation
import SwiftData

struct ReconciliationReport {
    let matched: [ImportedTransaction]
    let missingInApp: [ImportedTransaction]
}

struct ReconciliationEngine {
    func compare(imported: [ImportedTransaction], existing: [Transaction]) -> ReconciliationReport {
        let calendar = Calendar.current

        var usedExistingIDs: Set<Transaction.ID> = []

        let matched = imported.filter { importedTransaction in
            // 账单行没有商户名多半是解析失败，不能只凭金额和日期就认成"已记录"——
            // 那会把一笔真正缺失的交易藏进"已匹配"里
            guard !importedTransaction.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return existing.contains { transaction in
                guard !usedExistingIDs.contains(transaction.id) else { return false }
                let isMatch = amountsMatch(importedTransaction, transaction) &&
                    datesWithinRange(importedTransaction.transactionDate, transaction.date, calendar: calendar)
                if isMatch {
                    usedExistingIDs.insert(transaction.id)
                }
                return isMatch
            }
        }

        let missing = imported.filter { importedTransaction in
            !matched.contains(where: { $0.id == importedTransaction.id })
        }

        return ReconciliationReport(matched: matched, missingInApp: missing)
    }

    private func amountsMatch(_ imported: ImportedTransaction, _ existing: Transaction) -> Bool {
        let importedAmount = imported.billingAmount
        if abs(importedAmount - existing.billingAmount) < 0.01 { return true }
        if abs(importedAmount - existing.amount) < 0.01 { return true }
        return false
    }

    private func datesWithinRange(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Bool {
        let leftDay = calendar.startOfDay(for: lhs)
        let rightDay = calendar.startOfDay(for: rhs)
        let dayDiff = calendar.dateComponents([.day], from: leftDay, to: rightDay).day ?? Int.max
        return abs(dayDiff) <= 3
    }
}


