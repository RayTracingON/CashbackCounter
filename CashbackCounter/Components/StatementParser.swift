import Foundation
import PDFKit
import UIKit

struct StatementMetadata {
    let totalBalance: Double?
    let transactions: [ImportedTransaction]
    let statementText: String?
    let cardLast4: String?
    let cardName: String?

    init(
        totalBalance: Double?,
        transactions: [ImportedTransaction],
        statementText: String? = nil,
        cardLast4: String? = nil,
        cardName: String? = nil
    ) {
        self.totalBalance = totalBalance
        self.transactions = transactions
        self.statementText = statementText
        self.cardLast4 = cardLast4
        self.cardName = cardName
    }
}

struct ImportedTransaction: Identifiable, Hashable {
    let id: UUID
    let transactionDate: Date
    let postDate: Date
    let merchant: String
    let billingAmount: Double
    let foreignAmount: Double?
    let foreignCurrency: String?
    let region: Region?
    let paymentMethod: PaymentMethod?
    let category: Category?
    let rawText: String?

    init(
        id: UUID = UUID(),
        transactionDate: Date,
        postDate: Date,
        merchant: String,
        billingAmount: Double,
        foreignAmount: Double? = nil,
        foreignCurrency: String? = nil,
        region: Region? = nil,
        paymentMethod: PaymentMethod? = nil,
        category: Category? = nil,
        rawText: String? = nil
    ) {
        self.id = id
        self.transactionDate = transactionDate
        self.postDate = postDate
        self.merchant = merchant
        self.billingAmount = billingAmount
        self.foreignAmount = foreignAmount
        self.foreignCurrency = foreignCurrency
        self.region = region
        self.paymentMethod = paymentMethod
        self.category = category
        self.rawText = rawText
    }
}

struct StatementParser {
    @available(macOS 26.0, iOS 26.0, *)
    func parse(from url: URL) async -> StatementMetadata? {
        guard let images = await renderPages(from: url) else { return nil }
        
        var allRowsText = ""
        var fullDocumentText = ""
        let analyzer = StatementAnalyzer()
        
        for image in images {
            let rows = await analyzer.analyze(image: image)
            
            for row in rows {
                // Convert Y-clustered elements into a markdown-like table row
                let rowText = "| " + row.elements.map(\.text).joined(separator: " | ") + " |"
                allRowsText += rowText + "\n"
                
                // Keep standard space-separated text for balance/date heuristics
                fullDocumentText += row.text + "\n"
            }
            allRowsText += "\n"
        }

        let totalBalance = extractTotalBalance(from: fullDocumentText)
        let statementDate = extractStatementDate(from: fullDocumentText)
        
        // Filter to only transaction-relevant rows before sending to model
        let filteredRowsText = extractTransactionRows(from: allRowsText)
        StatementDebugLogger.log("Filtered rows: \(filteredRowsText.count) chars (was \(allRowsText.count))")

        // Pass the filtered markdown table to the bulk LLM parser
        let transactions = await parseTransactions(fromTables: filteredRowsText, statementDate: statementDate)

        return StatementMetadata(
            totalBalance: totalBalance,
            transactions: transactions,
            statementText: fullDocumentText
        )
    }

    // MARK: - Transaction Section Extraction

    /// Keywords that mark the START of a transaction section.
    private static let transactionStartKeywords: [String] = [
        // English
        "transaction", "transactions", "transaction details",
        "new transactions", "new charges", "purchases",
        "card transactions", "retail transactions",
        "payment and credits", "payments and other credits",
        // Chinese (Traditional / Simplified)
        "交易明細", "交易明细", "交易記錄", "交易记录",
        "簽賬項目", "签账项目", "消費明細", "消费明细",
        // Japanese
        "ご利用明細", "ご利用代金明細", "お取引明細"
    ]

    /// Keywords that mark the END of a transaction section (start of non-transaction content).
    private static let transactionEndKeywords: [String] = [
        // English
        "interest charge", "finance charge", "fees",
        "account summary", "statement summary", "summary of account",
        "important notice", "important information",
        "terms and conditions", "contact us", "customer service",
        "reward", "points summary", "cashback summary",
        "minimum payment", "payment due", "total amount due",
        "credit limit", "available credit",
        // Chinese
        "利息", "費用", "费用", "積分", "积分",
        "繳款", "缴款", "還款", "还款摘要",
        "重要通知", "條款", "条款",
        // Japanese
        "利息", "手数料", "お支払い", "ご返済"
    ]

    /// Extract only the rows that belong to transaction sections.
    /// Uses section header detection to find transaction blocks and skip
    /// irrelevant content (summaries, legal notices, interest, fees, etc.).
    func extractTransactionRows(from allRowsText: String) -> String {
        let lines = allRowsText.components(separatedBy: "\n")
        var filteredLines: [String] = []
        var inTransactionSection = false

        for line in lines {
            let stripped = line
                .replacingOccurrences(of: "|", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = stripped.lowercased()

            // Check for section boundaries
            if Self.transactionStartKeywords.contains(where: { lower.contains($0) }),
               !looksLikeDataRow(stripped) {
                inTransactionSection = true
                continue // skip the header row itself
            }

            if inTransactionSection,
               Self.transactionEndKeywords.contains(where: { lower.contains($0) }),
               !looksLikeDataRow(stripped) {
                inTransactionSection = false
                continue
            }

            if inTransactionSection {
                // Skip noise rows even within a transaction section
                if !isLikelyNoise(stripped) {
                    filteredLines.append(line)
                }
            }
        }

        // Fallback: if no section headers were detected, return original text
        // (some statements don't have clear section headers)
        if filteredLines.isEmpty {
            return allRowsText
        }

        return filteredLines.joined(separator: "\n")
    }

    /// A data row typically contains a dollar amount — this distinguishes
    /// actual transaction rows from section headers that happen to contain keywords.
    func looksLikeDataRow(_ text: String) -> Bool {
        let amountRegex = try? NSRegularExpression(pattern: "\\d+[,.]\\d{2}")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return (amountRegex?.firstMatch(in: text, range: range)) != nil
    }

    /// Filter out individual rows that are clearly not transaction data.
    func isLikelyNoise(_ stripped: String) -> Bool {
        // Empty or very short rows
        if stripped.count < 3 { return true }

        let lower = stripped.lowercased()

        // Page markers / footers
        if lower.hasPrefix("page ") && stripped.count < 20 { return true }
        if lower.contains("continued on") || lower.contains("continued from") { return true }

        // Column headers that repeat on every page
        let headerPatterns = [
            "posting date", "transaction date", "description", "amount",
            "date posted", "date of transaction", "reference number",
            "記帳日", "交易日", "摘要", "金額", "卡號"
        ]
        let matchCount = headerPatterns.filter { lower.contains($0) }.count
        if matchCount >= 2 { return true }

        return false
    }

    private func parseTransactions(
        fromTables tablesText: String,
        statementDate: Date?
    ) async -> [ImportedTransaction] {
        guard !tablesText.isEmpty else { return [] }

        let chunks = splitIntoChunks(text: tablesText, maxCharacters: 900)
        var parsed: [StatementRowTransaction] = []
        let parser = ReceiptParser()

        for chunk in chunks {
            do {
                let list = try await parser.parseStatementTransactionsBatch(text: chunk)
                parsed.append(contentsOf: list.transactions)
            } catch {
                print("Statement batch parse failed for chunk: \(error)")
            }
        }

        if parsed.isEmpty {
            return []
        }

        return buildImportedTransactions(from: parsed, statementDate: statementDate)
    }

    /// Split markdown table text into chunks that stay within the Foundation Models
    /// context window (4096 tokens). Each chunk keeps complete rows to avoid
    /// cutting a transaction in half.
    private func splitIntoChunks(text: String, maxCharacters: Int) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [String] = []
        var currentChunk: [String] = []
        var currentLength = 0

        for line in lines {
            let lineLength = line.count + 1 // +1 for newline
            if currentLength + lineLength > maxCharacters && !currentChunk.isEmpty {
                chunks.append(currentChunk.joined(separator: "\n"))
                currentChunk = []
                currentLength = 0
            }
            currentChunk.append(line)
            currentLength += lineLength
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk.joined(separator: "\n"))
        }

        return chunks
    }

    private func buildImportedTransactions(
        from parsed: [StatementRowTransaction],
        statementDate: Date?
    ) -> [ImportedTransaction] {
        var results: [ImportedTransaction] = []

        for item in parsed {
            let merchant = item.merchant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !merchant.isEmpty else { continue }
            guard let billingAmount = item.billingAmount else { continue }

            guard let transactionDate = parseStatementDate(from: item.transactionDate, statementDate: statementDate) else { continue }

            let normalizedBilling = abs(billingAmount)
            let normalizedForeign = item.foreignAmount.map { abs($0) }
            let transaction = ImportedTransaction(
                transactionDate: transactionDate,
                postDate: transactionDate,
                merchant: merchant,
                billingAmount: normalizedBilling,
                foreignAmount: normalizedForeign,
                foreignCurrency: item.foreignCurrency
            )
            results.append(transaction)
        }

        return results
    }

    private func parseStatementDate(from value: String?, statementDate: Date?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return parseDateToken(value, statementDate: statementDate)
    }

    private func renderPages(from url: URL) async -> [UIImage]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let document = PDFDocument(url: url) else {
                    continuation.resume(returning: nil)
                    return
                }

                var images: [UIImage] = []
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    if let image = renderPageImage(from: page, maxDimension: Self.maxPageDimension) {
                        images.append(image)
                    }
                }
                continuation.resume(returning: images)
            }
        }
    }

    private func renderPageImage(from page: PDFPage, maxDimension: CGFloat) -> UIImage? {
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }

        let maxSide = max(pageRect.width, pageRect.height)
        let scale = min(1, maxDimension / maxSide)
        let targetSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))

            let cgContext = context.cgContext
            cgContext.saveGState()
            // Flip PDF coordinates and apply scaling to avoid oversized renders.
            cgContext.translateBy(x: 0, y: targetSize.height)
            cgContext.scaleBy(x: scale, y: -scale)
            cgContext.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
            page.draw(with: .mediaBox, to: cgContext)
            cgContext.restoreGState()
        }
    }

    private func parseTransactions(from lines: [String], statementDate: Date?) -> [ImportedTransaction] {
        var results: [ImportedTransaction] = []
        var currentBlock: [String] = []

        for line in lines {
            if isTransactionStart(line, statementDate: statementDate) {
                if let transaction = parseTransactionBlock(currentBlock, statementDate: statementDate) {
                    results.append(transaction)
                }
                currentBlock = [line]
            } else if !currentBlock.isEmpty {
                currentBlock.append(line)
            }
        }

        if let transaction = parseTransactionBlock(currentBlock, statementDate: statementDate) {
            results.append(transaction)
        }

        return results
    }

    private func parseTransactionBlock(
        _ blockLines: [String],
        statementDate: Date?
    ) -> ImportedTransaction? {
        guard !blockLines.isEmpty else { return nil }
        let rawText = blockLines.joined(separator: "\n")
        var buffer = ""

        for line in blockLines {
            buffer = buffer.isEmpty ? line : buffer + " " + line
            if let transaction = parseTransactionLine(buffer, statementDate: statementDate) {
                return applyRawText(rawText, to: transaction)
            }
        }

        return nil
    }

    private func parseTransactionLine(_ line: String, statementDate: Date?) -> ImportedTransaction? {
        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 4 else { return nil }

        guard let (postDate, indexAfterPost) = consumeDate(from: tokens, startingAt: 0, statementDate: statementDate),
              let (transactionDate, indexAfterTransaction) = consumeDate(from: tokens, startingAt: indexAfterPost, statementDate: statementDate) else {
            return nil
        }

        var nextIndex = indexAfterTransaction
        if let (duplicatePost, dupIndex) = consumeDate(from: tokens, startingAt: nextIndex, statementDate: statementDate),
           let (duplicateTransaction, dupIndex2) = consumeDate(from: tokens, startingAt: dupIndex, statementDate: statementDate) {
            let calendar = Calendar.current
            let dupMatchesPost = calendar.isDate(duplicatePost, inSameDayAs: postDate)
            let dupMatchesTransaction = calendar.isDate(duplicatePost, inSameDayAs: transactionDate)
            let dupSecondMatchesPost = calendar.isDate(duplicateTransaction, inSameDayAs: postDate)
            let dupSecondMatchesTransaction = calendar.isDate(duplicateTransaction, inSameDayAs: transactionDate)

            if (dupMatchesPost && dupSecondMatchesTransaction) ||
                (dupMatchesTransaction && dupSecondMatchesPost) ||
                (dupMatchesPost && dupSecondMatchesPost) {
                nextIndex = dupIndex2
            }
        }

        let remainderTokens = Array(tokens.dropFirst(nextIndex))
        guard let parsed = splitAmounts(from: remainderTokens) else { return nil }
        guard let billingAmount = parsed.amounts.last else { return nil }

        let cleanedDescription = parsed.description.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !cleanedDescription.isEmpty else { return nil }
        guard !shouldIgnoreTransaction(cleanedDescription) else { return nil }

        let extracted = extractForeignDetails(from: cleanedDescription)
        var merchant = extracted.merchant
        var foreignAmount = extracted.amount
        let foreignCurrency = extracted.currency

        if foreignAmount == nil {
            if parsed.amounts.count >= 2 {
                foreignAmount = parsed.amounts[parsed.amounts.count - 2]
            } else if let trailing = extractTrailingAmount(from: merchant) {
                merchant = trailing.merchant
                foreignAmount = trailing.amount
            } else if let fallbackAmount = extractSecondaryAmount(from: line) {
                foreignAmount = fallbackAmount
            }
        }

        let normalizedBilling = abs(billingAmount)
        let normalizedForeign = foreignAmount.map { abs($0) }
        return ImportedTransaction(
            transactionDate: transactionDate,
            postDate: postDate,
            merchant: merchant,
            billingAmount: normalizedBilling,
            foreignAmount: normalizedForeign,
            foreignCurrency: foreignCurrency
        )
    }

    private func isTransactionStart(_ line: String, statementDate: Date?) -> Bool {
        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 2 else { return false }
        guard let (_, indexAfterPost) = consumeDate(from: tokens, startingAt: 0, statementDate: statementDate) else { return false }
        guard consumeDate(from: tokens, startingAt: indexAfterPost, statementDate: statementDate) != nil else { return false }
        return true
    }

    private func extractStatementDate(from text: String) -> Date? {
        let lines = text.components(separatedBy: .newlines)
        let datePattern = regex("(\\d{1,2}\\s*[A-Za-z]{3}\\s*\\d{2,4}|\\d{1,2}[A-Za-z]{3}\\d{2,4}|\\d{1,2}\\/\\d{1,2}\\/\\d{2,4}|\\d{4}-\\d{1,2}-\\d{1,2}|\\d{4}[\\/\\.:]\\d{1,2}[\\/\\.:]\\d{1,2})")

        for line in lines {
            let lower = line.lowercased()
            guard lower.contains("statement date") else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = datePattern.matches(in: line, range: range)
            for match in matches {
                guard let candidate = rangeString(match.range(at: 1), in: line) else { continue }
                if let date = parseDateToken(candidate, statementDate: nil) {
                    return date
                }
            }
        }

        return nil
    }

    private func consumeDate(
        from tokens: [Substring],
        startingAt index: Int,
        statementDate: Date?
    ) -> (date: Date, nextIndex: Int)? {
        guard index < tokens.count else { return nil }
        let maxIndex = tokens.count - 1

        let candidates: [(String, Int)] = [
            index + 2 <= maxIndex ? (String(tokens[index]) + String(tokens[index + 1]) + String(tokens[index + 2]), 3) : ("", 0),
            index + 2 <= maxIndex ? (String(tokens[index]) + " " + String(tokens[index + 1]) + " " + String(tokens[index + 2]), 3) : ("", 0),
            index + 1 <= maxIndex ? (String(tokens[index]) + String(tokens[index + 1]), 2) : ("", 0),
            index + 1 <= maxIndex ? (String(tokens[index]) + " " + String(tokens[index + 1]), 2) : ("", 0),
            (String(tokens[index]), 1)
        ]

        for (candidate, length) in candidates where length > 0 {
            if let date = parseDateToken(candidate, statementDate: statementDate) {
                return (date: date, nextIndex: index + length)
            }
        }

        return nil
    }

    private func parseDateToken(_ token: String, statementDate: Date?) -> Date? {
        let trimmed = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",."))
        guard !trimmed.isEmpty else { return nil }

        if let date = parseMonthNameDate(trimmed, statementDate: statementDate) {
            return date
        }

        if let date = parseCompactMonthDayYear(trimmed) {
            return date
        }

        let compact = trimmed
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        if let date = parseMonthAbbreviationDate(compact, statementDate: statementDate) {
            return date
        }

        let separatorCount = trimmed.filter { "/-.:".contains($0) }.count
        let hasSlashOrDash = trimmed.contains("/") || trimmed.contains("-")
        let shouldTryNumeric = hasSlashOrDash || separatorCount >= 2
        if shouldTryNumeric {
            for formatter in Self.numericDateFormatters {
                if let date = formatter.date(from: trimmed) {
                    return date
                }
            }
        }

        if shouldTryNumeric {
            let normalized = trimmed
                .replacingOccurrences(of: ".", with: "/")
                .replacingOccurrences(of: ":", with: "/")
                .replacingOccurrences(of: "-", with: "/")
            for formatter in Self.numericDateFormatters {
                if let date = formatter.date(from: normalized) {
                    return date
                }
            }

            if let date = parseYearFirstDate(normalized) {
                return date
            }

            if let date = parseSlashDateWithoutYear(normalized, statementDate: statementDate) {
                return date
            }
        }

        return nil
    }

    private func parseCompactMonthDayYear(_ token: String) -> Date? {
        let cleaned = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",."))
        let parts = cleaned.split { $0 == "/" || $0 == "-" }
        guard parts.count == 2 else { return nil }

        let monthDayToken = String(parts[0].filter { $0.isNumber })
        let yearToken = String(parts[1].filter { $0.isNumber })
        guard monthDayToken.count == 4, (yearToken.count == 2 || yearToken.count == 4) else { return nil }
        let monthString = monthDayToken.prefix(2)
        let dayString = monthDayToken.suffix(2)
        guard let month = Int(monthString), let day = Int(dayString) else { return nil }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }

        let year = normalizeYear(from: yearToken)
        return makeDate(day: day, month: month, year: year)
    }

    private func parseMonthNameDate(_ token: String, statementDate: Date?) -> Date? {
        let cleaned = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: " ")
        let normalized = cleaned
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        let upper = normalized.uppercased()
        let parts = upper.split(whereSeparator: { $0.isWhitespace })

        if parts.count >= 2 {
            let monthToken = String(parts[0])
            let dayToken = String(parts[1].filter { $0.isNumber })
            if let month = Self.monthNameMap[monthToken],
               let day = Int(dayToken) {
                let year: Int
                if parts.count >= 3 {
                    let yearToken = String(parts[2].filter { $0.isNumber })
                    if Int(yearToken) != nil {
                        year = normalizeYear(from: yearToken)
                    } else {
                        year = inferredYear(for: month, statementDate: statementDate)
                    }
                } else {
                    year = inferredYear(for: month, statementDate: statementDate)
                }
                return makeDate(day: day, month: month, year: year)
            }
        }

        let monthPattern = regex("^(JANUARY|JAN|FEBRUARY|FEB|MARCH|MAR|APRIL|APR|MAY|JUNE|JUN|JULY|JUL|AUGUST|AUG|SEPTEMBER|SEP|OCTOBER|OCT|NOVEMBER|NOV|DECEMBER|DEC)(\\d{1,2})(\\d{2,4})?$")
        let dayMonthPattern = regex("^(\\d{1,2})(JANUARY|JAN|FEBRUARY|FEB|MARCH|MAR|APRIL|APR|MAY|JUNE|JUN|JULY|JUL|AUGUST|AUG|SEPTEMBER|SEP|OCTOBER|OCT|NOVEMBER|NOV|DECEMBER|DEC)(\\d{2,4})?$")

        let patterns: [(NSRegularExpression, Bool)] = [
            (monthPattern, true),
            (dayMonthPattern, false)
        ]
        for (pattern, isMonthFirst) in patterns {
            let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
            guard let match = pattern.firstMatch(in: upper, range: range), match.numberOfRanges >= 3 else { continue }
            if isMonthFirst {
                guard let monthToken = rangeString(match.range(at: 1), in: upper),
                      let dayString = rangeString(match.range(at: 2), in: upper) else { continue }
                guard let month = Self.monthNameMap[monthToken], let day = Int(dayString) else { continue }
                let year = (match.numberOfRanges >= 4 ? rangeString(match.range(at: 3), in: upper) : nil)
                    .flatMap { Int($0) }
                    .map { normalizeYear(from: String($0)) }
                    ?? inferredYear(for: month, statementDate: statementDate)
                return makeDate(day: day, month: month, year: year)
            } else {
                guard let dayString = rangeString(match.range(at: 1), in: upper),
                      let monthToken = rangeString(match.range(at: 2), in: upper) else { continue }
                guard let month = Self.monthNameMap[monthToken], let day = Int(dayString) else { continue }
                let year = (match.numberOfRanges >= 4 ? rangeString(match.range(at: 3), in: upper) : nil)
                    .flatMap { Int($0) }
                    .map { normalizeYear(from: String($0)) }
                    ?? inferredYear(for: month, statementDate: statementDate)
                return makeDate(day: day, month: month, year: year)
            }
        }

        return nil
    }

    private func parseYearFirstDate(_ token: String) -> Date? {
        let cleaned = token.replacingOccurrences(of: " ", with: "")
        if cleaned.count == 8, let year = Int(cleaned.prefix(4)) {
            let monthString = cleaned.dropFirst(4).prefix(2)
            let dayString = cleaned.suffix(2)
            if let month = Int(monthString), let day = Int(dayString) {
                return makeDate(day: day, month: month, year: year)
            }
        }

        if cleaned.count == 9, let year = Int(cleaned.prefix(4)) {
            let rest = cleaned.dropFirst(5)
            if rest.count == 4 {
                let monthString = rest.prefix(2)
                let dayString = rest.suffix(2)
                if let month = Int(monthString), let day = Int(dayString) {
                    return makeDate(day: day, month: month, year: year)
                }
            }
        }

        let parts = cleaned.split(separator: "/")
        if parts.count == 2, parts[0].count == 4, parts[1].count == 4,
           let year = Int(parts[0]) {
            let monthString = parts[1].prefix(2)
            let dayString = parts[1].suffix(2)
            if let month = Int(monthString), let day = Int(dayString) {
                return makeDate(day: day, month: month, year: year)
            }
        }

        return nil
    }

    private func parseMonthAbbreviationDate(_ token: String, statementDate: Date?) -> Date? {
        let pattern = regex("^(\\d{1,2})([A-Z]{3})(\\d{2,4})?$")
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        guard let match = pattern.firstMatch(in: token, range: range), match.numberOfRanges >= 3 else { return nil }
        guard let dayString = rangeString(match.range(at: 1), in: token),
              let monthString = rangeString(match.range(at: 2), in: token) else { return nil }

        let monthMap: [String: Int] = [
            "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
            "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12
        ]
        guard let day = Int(dayString), let month = monthMap[monthString] else { return nil }

        let year: Int
        if match.numberOfRanges >= 4, let yearString = rangeString(match.range(at: 3), in: token), !yearString.isEmpty {
            year = normalizeYear(from: yearString)
        } else {
            year = inferredYear(for: month, statementDate: statementDate)
        }

        return makeDate(day: day, month: month, year: year)
    }

    private func parseSlashDateWithoutYear(_ token: String, statementDate: Date?) -> Date? {
        let parts = token.split(separator: "/")
        guard parts.count == 2 else { return nil }
        guard let first = Int(parts[0]), let second = Int(parts[1]) else { return nil }

        let day: Int
        let month: Int
        if first > 12 {
            day = first
            month = second
        } else if second > 12 {
            day = second
            month = first
        } else {
            day = first
            month = second
        }

        let year = inferredYear(for: month, statementDate: statementDate)
        return makeDate(day: day, month: month, year: year)
    }

    private func normalizeYear(from string: String) -> Int {
        if string.count == 2, let year = Int(string) {
            return 2000 + year
        }
        return Int(string) ?? Calendar.current.component(.year, from: Date())
    }

    private func inferredYear(for month: Int, statementDate: Date?) -> Int {
        let calendar = Calendar.current
        let baseYear = statementDate.map { calendar.component(.year, from: $0) } ?? calendar.component(.year, from: Date())
        guard let statementDate else { return baseYear }
        let statementMonth = calendar.component(.month, from: statementDate)
        if month - statementMonth >= 6 {
            return baseYear - 1
        }
        return baseYear
    }

    private func makeDate(day: Int, month: Int, year: Int) -> Date? {
        var components = DateComponents()
        components.day = day
        components.month = month
        components.year = year
        return Calendar.current.date(from: components)
    }

    private func splitAmounts(from tokens: [Substring]) -> (description: String, amounts: [Double])? {
        guard !tokens.isEmpty else { return nil }
        var amounts: [Double] = []
        var amountStartIndex: Int?
        var index = tokens.count - 1
        var pendingCredit = false

        while index >= 0 {
            let token = tokens[index]
            let upper = token.uppercased()

            if upper == "CR" || upper == "CREDIT" {
                pendingCredit = true
                index -= 1
                continue
            }

            if isCurrencyToken(token) {
                index -= 1
                continue
            }

            if let amount = parseAmountToken(token, forceNegative: pendingCredit) {
                amounts.insert(amount, at: 0)
                pendingCredit = false
                amountStartIndex = index
                index -= 1
                continue
            }

            if !amounts.isEmpty {
                break
            }
            index -= 1
        }

        guard let startIndex = amountStartIndex else { return nil }

        var descriptionTokens = Array(tokens[..<startIndex])
        while let last = descriptionTokens.last, isCurrencyToken(last) {
            descriptionTokens.removeLast()
        }
        let description = descriptionTokens.joined(separator: " ")
        return (description: description, amounts: amounts)
    }

    private func isCurrencyToken(_ token: Substring) -> Bool {
        let upper = token.uppercased()
        let currencies = ["HKD", "USD", "SGD", "JPY", "CNY", "RMB", "EUR", "GBP", "AUD", "CAD", "TWD", "$", "HK$", "US$"]
        return currencies.contains(upper)
    }

    private func parseAmountToken(_ token: Substring, forceNegative: Bool) -> Double? {
        guard let parsed = parseAmount(String(token)) else { return nil }
        return forceNegative ? -abs(parsed) : parsed
    }

    private func shouldIgnoreTransaction(_ description: String) -> Bool {
        let upper = description.uppercased()
        let ignoreKeywords = ["PREVIOUS BALANCE", "BALANCE FORWARD"]
        return ignoreKeywords.contains(where: { upper.contains($0) })
    }

    private func applyRawText(_ rawText: String, to transaction: ImportedTransaction) -> ImportedTransaction {
        ImportedTransaction(
            id: transaction.id,
            transactionDate: transaction.transactionDate,
            postDate: transaction.postDate,
            merchant: transaction.merchant,
            billingAmount: transaction.billingAmount,
            foreignAmount: transaction.foreignAmount,
            foreignCurrency: transaction.foreignCurrency,
            region: transaction.region,
            paymentMethod: transaction.paymentMethod,
            category: transaction.category,
            rawText: rawText
        )
    }

    private func extractTrailingAmount(from text: String) -> (merchant: String, amount: Double)? {
        let trailingRegex = regex("^(.*?)(?:\\s+)(" + amountPattern + ")$")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = trailingRegex.firstMatch(in: text, range: range), match.numberOfRanges == 3 else {
            return nil
        }
        guard let merchant = rangeString(match.range(at: 1), in: text),
              let amountString = rangeString(match.range(at: 2), in: text),
              let amount = parseAmount(amountString) else {
            return nil
        }
        return (merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines), amount: amount)
    }

    private func extractSecondaryAmount(from text: String) -> Double? {
        let amountRegex = regex(amountPattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = amountRegex.matches(in: text, range: range)
        guard matches.count >= 2 else { return nil }
        let targetIndex = matches.count - 2
        guard let amountString = rangeString(matches[targetIndex].range, in: text) else { return nil }
        return parseAmount(amountString)
    }

    private func extractTotalBalance(from text: String) -> Double? {
        let keywords = ["New Balance", "Statement Balance", "Total Balance", "Balance Due", "Closing Balance"]
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            guard keywords.contains(where: { line.localizedCaseInsensitiveContains($0) }) else { continue }
            if let amount = extractFirstAmount(from: line) {
                return amount
            }
        }

        return extractFirstAmount(from: text)
    }

    private func extractFirstAmount(from text: String) -> Double? {
        let amountRegex = regex(amountPattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = amountRegex.firstMatch(in: text, range: range) else { return nil }
        guard let amountString = rangeString(match.range(at: 0), in: text) else { return nil }
        return parseAmount(amountString)
    }

    private func extractForeignDetails(from description: String) -> (merchant: String, currency: String?, amount: Double?) {
        let patterns = ["([A-Z]{3})\\s*([0-9]+(?:\\.[0-9]{2})?)", "([0-9]+(?:\\.[0-9]{2})?)\\s*([A-Z]{3})"]

        for pattern in patterns {
            let detailRegex = regex(pattern)
            let range = NSRange(description.startIndex..<description.endIndex, in: description)
            guard let match = detailRegex.firstMatch(in: description, range: range), match.numberOfRanges == 3 else {
                continue
            }

            guard let first = rangeString(match.range(at: 1), in: description),
                  let second = rangeString(match.range(at: 2), in: description) else {
                continue
            }

            let currency: String
            let amountString: String
            if first.count == 3 {
                currency = first
                amountString = second
            } else {
                currency = second
                amountString = first
            }

            guard let amount = Double(amountString) else { continue }

            var merchant = description
            if let removeRange = Range(match.range(at: 0), in: description) {
                merchant.removeSubrange(removeRange)
            }
            merchant = merchant.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

            return (merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines), currency: currency, amount: amount)
        }

        return (merchant: description.trimmingCharacters(in: .whitespacesAndNewlines), currency: nil, amount: nil)
    }

    private func parseAmount(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var isNegative = false

        let upper = text.uppercased()
        if upper.contains("CR") {
            isNegative = true
            text = text.replacingOccurrences(of: "CR", with: "", options: .caseInsensitive)
        }

        if text.contains("(") && text.contains(")") {
            isNegative = true
            text = text.replacingOccurrences(of: "(", with: "")
            text = text.replacingOccurrences(of: ")", with: "")
        }

        if text.hasPrefix("-") {
            isNegative = true
            text.removeFirst()
        }

        text = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "HK$", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "US$", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "$", with: "")

        let filtered = text.filter { $0.isNumber || $0 == "." }
        guard let value = Double(filtered) else { return nil }
        return isNegative ? -value : value
    }

    private func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private func rangeString(_ range: NSRange, in text: String) -> String? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private func regex(_ pattern: String) -> NSRegularExpression {
        return (try? NSRegularExpression(pattern: pattern, options: [])) ?? (try! NSRegularExpression(pattern: "(?!)"))
    }

    private static let numericDateFormatters: [DateFormatter] = {
        let formats = [
            "MM/dd/yy",
            "MM/dd/yyyy",
            "dd/MM/yy",
            "dd/MM/yyyy",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "yyyy/M/d"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.isLenient = false
            return formatter
        }
    }()

    private static let monthNameMap: [String: Int] = [
        "JAN": 1, "JANUARY": 1,
        "FEB": 2, "FEBRUARY": 2,
        "MAR": 3, "MARCH": 3,
        "APR": 4, "APRIL": 4,
        "MAY": 5,
        "JUN": 6, "JUNE": 6,
        "JUL": 7, "JULY": 7,
        "AUG": 8, "AUGUST": 8,
        "SEP": 9, "SEPTEMBER": 9,
        "OCT": 10, "OCTOBER": 10,
        "NOV": 11, "NOVEMBER": 11,
        "DEC": 12, "DECEMBER": 12
    ]

    private let amountPattern = "-?[A-Za-z$]{0,4}\\s*\\(?[\\d,]+\\.\\d{2}\\)?(?:[cC][rR])?"
    private static let maxPageDimension: CGFloat = 2500
}
