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
            return selectedDate.formatted(.dateTime.year()) + " 全年"
        } else {
            return selectedDate.formatted(.dateTime.year().month())
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

    func exchangeRate(for currencyCode: String, mainCurrencyCode: String) -> Double {
        if currencyCode == mainCurrencyCode { return 1.0 }
        if let rate = exchangeRates[currencyCode] { return rate }
        if let rate = exchangeRates[currencyCode.uppercased()] { return rate }
        if let rate = exchangeRates[currencyCode.lowercased()] { return rate }
        return 1.0
    }

    func billingCurrencyCode(for transaction: Transaction) -> String {
        transaction.resolvedBillingCurrencyCode
    }

    func expenseInMainCurrency(for transaction: Transaction, mainCurrencyCode: String) -> (amount: Double, currencyCode: String) {
        let code = billingCurrencyCode(for: transaction)
        let rate = exchangeRate(for: code, mainCurrencyCode: mainCurrencyCode)
        return (transaction.billingAmount / rate, code)
    }

    func incomeInMainCurrency(for transaction: Transaction, mainCurrencyCode: String) -> Double {
        (transaction.incomes ?? []).reduce(0) { partial, income in
            let incomeRate = exchangeRate(for: income.location.currencyCode, mainCurrencyCode: mainCurrencyCode)
            return partial + (income.amount / incomeRate)
        }
    }

    // MARK: - Totals

    func totalExpense(from transactions: [Transaction], mainCurrencyCode: String) -> Double {
        if exchangeRates.isEmpty { return 0.0 }
        return transactions.reduce(0) { total, t in
            let expenseInfo = expenseInMainCurrency(for: t, mainCurrencyCode: mainCurrencyCode)
            let incomeInMain = incomeInMainCurrency(for: t, mainCurrencyCode: mainCurrencyCode)
            return total + (expenseInfo.amount - incomeInMain)
        }
    }

    func totalCashback(from transactions: [Transaction], mainCurrencyCode: String) -> Double {
        if exchangeRates.isEmpty { return 0.0 }
        return transactions.reduce(0) { total, t in
            let cb = CashbackService.calculateCashback(for: t)
            // 返现随入账币种计价 (双币卡副币入账的返现也是副币)
            let code = t.card != nil ? t.resolvedBillingCurrencyCode : mainCurrencyCode
            let rate = exchangeRate(for: code, mainCurrencyCode: mainCurrencyCode)
            return total + (cb / rate)
        }
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
                if url.pathExtension.lowercased() == "zip" {
                    try CSVHelper.importBackupZip(url: url, context: context, allCards: cards)
                    importMessage = "ZIP 备份导入成功！"
                } else {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    _ = try CSVHelper.parseTransactionCSV(content: content, context: context, allCards: cards)
                    importMessage = "CSV 导入成功！"
                }
                showImportAlert = true
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
        guard !didLogNegativeExpenses, !exchangeRates.isEmpty else { return }
        didLogNegativeExpenses = true

        let negativeItems = filteredTransactions.compactMap { transaction -> (Transaction, Double, Double, Double, String)? in
            let expenseInfo = expenseInMainCurrency(for: transaction, mainCurrencyCode: mainCurrencyCode)
            let income = incomeInMainCurrency(for: transaction, mainCurrencyCode: mainCurrencyCode)
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
    }

    // MARK: - Actions

    func deleteTransaction(_ transaction: Transaction, context: ModelContext) {
        context.delete(transaction)
    }

    func deleteIncome(_ income: Income, context: ModelContext) {
        context.delete(income)
        try? context.save()
    }
}
