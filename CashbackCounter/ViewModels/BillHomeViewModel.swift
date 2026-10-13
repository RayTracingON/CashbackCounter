//
//  BillHomeViewModel.swift
//  CashbackCounter
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@Observable
final class BillHomeViewModel {
    // MARK: - Sheet/Navigation State
    var selectedTransaction: Transaction? = nil
    var transactionToEdit: Transaction?
    var incomeTargetTransaction: Transaction?
    var incomeToEdit: Income?
    var showDatePicker = false

    // MARK: - Filter State
    var selectedDate = Date()
    var showAll = false
    var isWholeYear = true
    var selectedCategory: Category? = nil
    var showIncomeOnly = false

    // MARK: - Trend & Import State
    var showTrendSheet = false
    var showExpenseSheet = false
    var showFileImporter = false
    var showImportAlert = false
    var importMessage = ""
    var showStatementAnalysis = false
    var exportedFileURL: URL? = nil

    // MARK: - Data State
    var exchangeRates: [String: Double] = [:]
    var didLogNegativeExpenses = false

    // MARK: - Computed Helpers

    var dateButtonText: String {
        if isWholeYear {
            return selectedDate.formatted(.dateTime.year().locale(AppLanguage.locale)) + " " + String.loc("全年")
        } else {
            return selectedDate.formatted(.dateTime.year().month().locale(AppLanguage.locale))
        }
    }

    func expenseTitle(isSearchingActive: Bool) -> LocalizedStringKey {
        if isSearchingActive || showAll {
            return "总支出"
        }
        return isWholeYear ? "本年支出" : "本月支出"
    }

    func cashbackTitle(isSearchingActive: Bool) -> LocalizedStringKey {
        if isSearchingActive || showAll {
            return "总返现"
        }
        return isWholeYear ? "本年返现" : "本月返现"
    }

    // MARK: - Filtering Logic

    func filteredTransactions(from dbTransactions: [Transaction], searchText: String, isSearchPresented: Bool) -> [Transaction] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearchingActive = !trimmed.isEmpty

        if isSearchingActive {
            return dbTransactions
        }

        // 第一步：日期筛选
        var results = showAll ? dbTransactions : dbTransactions.filter { t in
            if isWholeYear {
                return Calendar.current.isDate(t.date, equalTo: selectedDate, toGranularity: .year)
            } else {
                return Calendar.current.isDate(t.date, equalTo: selectedDate, toGranularity: .month)
            }
        }

        // 第二步：按类别筛选
        if let category = selectedCategory {
            results = results.filter { $0.category == category }
        }

        // 第三步：按收入筛选
        if showIncomeOnly {
            results = results.filter { ($0.incomes?.isEmpty == false) }
        }

        return results
    }

    // MARK: - Exchange Rate Helpers

    /// 换算汇率；主币种自身为 1。缺这个币种时返回 nil ——
    /// 之前退回 1.0，断网时一笔 JPY 10,000 会被当成 ¥10,000 加进"本月支出"
    func exchangeRate(for currencyCode: String, mainCurrencyCode: String) -> Double? {
        if currencyCode == mainCurrencyCode { return 1.0 }
        if let rate = exchangeRates[currencyCode] { return rate }
        if let rate = exchangeRates[currencyCode.uppercased()] { return rate }
        if let rate = exchangeRates[currencyCode.lowercased()] { return rate }
        return nil
    }

    func billingCurrencyCode(for transaction: Transaction) -> String {
        transaction.resolvedBillingCurrencyCode
    }

    /// 入账金额换算到主币种；缺汇率返回 nil
    func expenseInMainCurrency(for transaction: Transaction, mainCurrencyCode: String) -> (amount: Double, currencyCode: String)? {
        let code = billingCurrencyCode(for: transaction)
        guard let rate = exchangeRate(for: code, mainCurrencyCode: mainCurrencyCode), rate > 0 else { return nil }
        return (transaction.billingAmount / rate, code)
    }

    /// 关联收入换算到主币种；任一笔缺汇率返回 nil
    func incomeInMainCurrency(for transaction: Transaction, mainCurrencyCode: String) -> Double? {
        var total = 0.0
        for income in transaction.incomes ?? [] {
            guard let rate = exchangeRate(for: income.location.currencyCode, mainCurrencyCode: mainCurrencyCode), rate > 0 else {
                return nil
            }
            total += income.amount / rate
        }
        return total
    }

    // MARK: - Totals

    /// 汇率还没到、或有任何一笔换不了汇时返回 nil，界面显示 "..." 而不是一个错的数
    func totalExpense(from transactions: [Transaction], mainCurrencyCode: String) -> Double? {
        if exchangeRates.isEmpty { return nil }
        var total = 0.0
        for t in transactions {
            guard let expense = expenseInMainCurrency(for: t, mainCurrencyCode: mainCurrencyCode),
                  let income = incomeInMainCurrency(for: t, mainCurrencyCode: mainCurrencyCode) else {
                return nil
            }
            total += expense.amount - income
        }
        return total
    }

    func totalCashback(from transactions: [Transaction], mainCurrencyCode: String) -> Double? {
        if exchangeRates.isEmpty { return nil }
        var total = 0.0
        for t in transactions {
            let cb = CashbackService.calculateCashback(for: t)
            // 返现卡随入账币种计价；积分卡的价值是按发卡币种估的（见 Transaction.rewardCurrencyCode）
            guard let rate = exchangeRate(for: t.rewardCurrencyCode, mainCurrencyCode: mainCurrencyCode), rate > 0 else {
                return nil
            }
            total += cb / rate
        }
        return total
    }

    // MARK: - Data Loading

    func loadExchangeRates(mainCurrencyCode: String) async {
        let rates = await CurrencyService.getRates(base: mainCurrencyCode)
        await MainActor.run {
            self.exchangeRates = rates
        }
    }

    // MARK: - File Import

    func handleFileImport(result: Result<[URL], Error>, context: ModelContext, cards: [CreditCard]) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let imported: [Transaction]
                if url.pathExtension.lowercased() == "zip" {
                    imported = try CSVHelper.importBackupZip(url: url, context: context, allCards: cards)
                    importMessage = "ZIP 备份导入成功！"
                } else {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    imported = try CSVHelper.parseTransactionCSV(content: content, context: context, allCards: cards)
                    importMessage = "CSV 导入成功！"
                }
                showImportAlert = true

                // 导入的交易散落在各个周期、也可能早于已有交易：涉及的卡整体按时间顺序重算奖励快照
                let affectedCards = Set(imported.compactMap(\.card))
                Task {
                    try? context.save()
                    for card in affectedCards {
                        await card.recalculateAllRewards()
                    }
                    try? context.save()
                }
            } catch {
                importMessage = "导入失败：\(error.localizedDescription)"
                showImportAlert = true
            }
        case .failure(let error):
            print("选择文件失败: \(error)")
        }
    }

    // MARK: - Debug Logging

    func logNegativeExpenseTransactions(filteredTransactions: [Transaction], mainCurrencyCode: String) {
        #if DEBUG
        guard !didLogNegativeExpenses, !exchangeRates.isEmpty else { return }
        didLogNegativeExpenses = true

        let negativeItems = filteredTransactions.compactMap { transaction -> (Transaction, Double, Double, Double, String)? in
            guard let expenseInfo = expenseInMainCurrency(for: transaction, mainCurrencyCode: mainCurrencyCode),
                  let income = incomeInMainCurrency(for: transaction, mainCurrencyCode: mainCurrencyCode) else { return nil }
            let net = expenseInfo.amount - income
            guard net < -0.0001 else { return nil }
            return (transaction, net, expenseInfo.amount, income, expenseInfo.currencyCode)
        }

        if negativeItems.isEmpty {
            print("NEG_EXPENSE_CHECK: no negative net expenses in current filter.")
            return
        }

        print("NEG_EXPENSE_CHECK: found \(negativeItems.count) negative net expense transactions.")
        for (transaction, net, expenseMain, incomeMain, billingCode) in negativeItems {
            let cardName = transaction.card.map { "\($0.bankName) \($0.type)" } ?? "无卡"
            let issueCode = transaction.card?.issueRegion.currencyCode ?? "-"
            let incomeCount = transaction.incomes?.count ?? 0
            print("""
NEG_EXPENSE | merchant=\(transaction.merchant) | date=\(transaction.dateString) | card=\(cardName) | issue=\(issueCode) | location=\(transaction.location.currencyCode) | amount=\(transaction.amount) | billing=\(transaction.billingAmount) \(billingCode) | expenseMain=\(expenseMain) | incomeMain=\(incomeMain) | netMain=\(net) | incomes=\(incomeCount)
""")
        }
        #endif
    }

    // MARK: - Actions

    func deleteTransaction(_ transaction: Transaction, context: ModelContext) {
        // 删掉之后它吃掉的额度要回到同周期其它交易身上
        Task { await Transaction.deleteRecalculating(transaction, in: context) }
    }

    func deleteIncome(_ income: Income, context: ModelContext) {
        context.delete(income)
        try? context.save()
    }
}
