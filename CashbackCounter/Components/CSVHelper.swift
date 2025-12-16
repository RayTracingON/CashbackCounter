//
//  CSVHelper.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/25/25.
//
import Foundation
import SwiftUI
import SwiftData
import ZIPFoundation

// 👇 1. 新增：专门负责导入解析的结构体
struct CSVHelper {
    
    // MARK: - Receipt filename helpers (shared by import/export)
    private static let receiptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
    
    private static func sanitizedMerchantComponent(_ merchant: String) -> String {
        let sanitized = merchant
            .replacingOccurrences(of: "[^A-Za-z0-9_\\u4e00-\\u9fa5-]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        
        // 限制最长 40 个字符，避免过长文件名导入时无法匹配
        let truncated = String(sanitized.prefix(40))
        return truncated.isEmpty ? "receipt" : truncated
    }
    
    fileprivate static func receiptFilename(for merchant: String, date: Date, index: Int) -> String {
        let dateString = receiptDateFormatter.string(from: date)
        let merchantComponent = sanitizedMerchantComponent(merchant)
        return "receipt_\(dateString)_\(merchantComponent)_\(index).jpg"
    }
    
    // MARK: - 导入交易逻辑
    static func importBackupZip(url: URL, context: ModelContext, allCards: [CreditCard]) throws {
            let fileManager = FileManager.default
            // 创建临时目录用于解压
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempDir) } // 结束后清理
            
            // 1. 解压文件
            try fileManager.unzipItem(at: url, to: tempDir)
            
            // 2. 寻找 CSV 文件
            // 注意：根据导出逻辑，CSV 可能直接在根目录，或者解压后的同名文件夹内
            // 这里假设结构是标准的: /Transactions.csv 和 /Receipts/
            let csvURL = tempDir.appendingPathComponent("Transactions.csv")
            
            guard fileManager.fileExists(atPath: csvURL.path) else {
                throw NSError(domain: "CSVHelper", code: 404, userInfo: [NSLocalizedDescriptionKey: "ZIP 文件中未找到 Transactions.csv"])
            }
            
            // 3. 读取 CSV 内容
            let content = try String(contentsOf: csvURL, encoding: .utf8)
            
            // 4. 定位收据文件夹 (如果存在)
            let receiptsDir = tempDir.appendingPathComponent("Receipts")
            let receiptsURL = fileManager.fileExists(atPath: receiptsDir.path) ? receiptsDir : nil
            
            // 5. 调用核心解析逻辑，并传入收据路径
            try parseTransactionCSV(content: content, context: context, allCards: allCards, receiptsDirectory: receiptsURL)
        }

        // MARK: - 导入 CSV 核心逻辑 (修改版)
        // 👇 新增 receiptsDirectory 参数
    static func parseTransactionCSV(content: String, context: ModelContext, allCards: [CreditCard], receiptsDirectory: URL? = nil) throws {
        let rows = content.components(separatedBy: .newlines)
        
        let categoryMap: [String: Category] = Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0.displayName, $0) })
        let regionMap: [String: Region] = Dictionary(uniqueKeysWithValues: Region.allCases.map { ($0.rawValue, $0) })
        
        for (index, row) in rows.enumerated() {
            // index 0 是表头，index 1 是第一条数据
            if index == 0 || row.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            
            let columns = splitCSVLine(row)
            if columns.count < 9 { continue }
            
            // 1. 解析基础字段
            let dateStr = columns[0]
            let merchant = cleanCSVField(columns[1])
            let categoryName = columns[2]
            let amount = Double(columns[3]) ?? 0.0
            let billing = Double(columns[4]) ?? 0.0
            let cashback = Double(columns[5]) ?? 0.0
            let cardNameRaw = cleanCSVField(columns[6])
            let cardEndNum = columns[7]
            let regionName = columns[8]
            
            let date = dateStr.toDate()
            let category = categoryMap[categoryName] ?? .other
            let cleanRegionName = regionName.trimmingCharacters(in: .whitespacesAndNewlines)
            let region = regionMap[cleanRegionName] ?? .cn
            
            // 2. 尝试匹配收据图片
            var receiptData: Data? = nil
            if let receiptsDir = receiptsDirectory {
                // 重建文件名逻辑 (必须与导出时完全一致)
                // 导出时用的逻辑: "receipt_\(dateString)_\(sanitizedMerchant)_\(index + 1).jpg"
                // 这里的 index 是 CSV 行号。
                // 导出循环: for (i, t) in self.enumerated() -> 对应文件名后缀 i+1
                // 导入循环: index 0 是 Header, index 1 是第一条数据。
                // 所以：第一条数据(行号1) 对应 文件后缀 1。
                // 结论：直接使用 index 即可。
                
                let filename = receiptFilename(for: merchant, date: date, index: index)
                let fileURL = receiptsDir.appendingPathComponent(filename)
                
                // 如果文件存在，读取数据
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    receiptData = try? Data(contentsOf: fileURL)
                }
            }
            
            // 3. 匹配卡片
            var matchedCard: CreditCard? = nil
            if cardEndNum != "无卡" && cardNameRaw != "已删除卡片" {
                matchedCard = allCards.first { card in
                    let dbCardName = "\(card.bankName) \(card.type)"
                    return card.endNum == cardEndNum && dbCardName == cardNameRaw
                }
                if matchedCard == nil {
                    matchedCard = allCards.first { $0.endNum == cardEndNum }
                }
            }
            
            // 4. 创建交易
            let newTransaction = Transaction(
                merchant: merchant,
                category: category,
                location: region,
                amount: amount,
                date: date,
                card: matchedCard,
                receiptData: receiptData, // 👈 传入读取到的图片数据
                billingAmount: billing,
                cashbackAmount: cashback
            )
            
            context.insert(newTransaction)
        }
    }
    
    // 🛠 辅助1：清理 CSV 字段 (去引号 + 还原转义)
    private static func cleanCSVField(_ text: String) -> String {
        var s = text
        // 如果前后有引号，去掉它们
        if s.hasPrefix("\"") && s.hasSuffix("\"") {
            s.removeFirst()
            s.removeLast()
        }
        // 还原 CSV 的双引号转义 ("" -> ")
        return s.replacingOccurrences(of: "\"\"", with: "\"")
    }
    
    // 🛠 辅助2：智能分割 CSV 行 (核心算法)
    // 能处理: 2025-01-01, "Starbucks, Inc.", Dining... 这种情况，不会在 Inc 后面的逗号切断
    private static func splitCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var insideQuotes = false
        
        for char in line {
            if char == "\"" {
                insideQuotes.toggle()
                current.append(char) // 保留引号，交给 cleanCSVField 处理
            } else if char == "," && !insideQuotes {
                // 只有在不在引号内遇到逗号，才算分列
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }
}

// 👇 你的 Extension 保持不变
extension Array where Element == Transaction {
    
    // 生成 CSV 文本内容
    func generateCSV() -> String {
        // ... (保持你发来的代码不变) ...
        // 1. 表头
        var csvString = "交易时间,商户名称,消费类别,消费金额(原币),入账金额(本币),返现金额(本币),支付卡片,卡片尾号,消费地区\n"
        
        // 2. 遍历
        for t in self {
            let date = t.dateString
            // ... (你之前的代码) ...
            let safeMerchant = t.merchant.replacingOccurrences(of: "\"", with: "\"\"")
            let merchant = "\"\(safeMerchant)\""
            
            // ... 其他字段 ...
            let category = t.category.displayName
            let amount = String(format: "%.2f", t.amount)
            let billing = String(format: "%.2f", t.billingAmount)
            let cashback = String(format: "%.2f", t.cashbackamount)
            let cardNumber = t.card?.endNum ?? "无卡"
            let cardName = t.card != nil ? "\"\(t.card!.bankName) \(t.card!.type)\"" : "已删除卡片"
            let region = t.location.rawValue
            
            let row = "\(date),\(merchant),\(category),\(amount),\(billing),\(cashback),\(cardName),\(cardNumber),\(region)\n"
            csvString.append(row)
        }
        return csvString
    }
    

    /// 导出带收据图片的压缩包，文件名中会包含交易日期与商户，便于识别。
    /// - Returns: 生成的 zip 文件 URL，如果当前没有收据则返回 nil。
    func exportReceiptsZip() -> URL? {
        let fileManager = FileManager.default
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = timestampFormatter.string(from: Date())
        
        // 1. 创建临时导出根目录 (例如: tmp/Cashback_Export_20251212_101010)
        let rootFolderName = "Cashback_Export_\(timestamp)"
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(rootFolderName)
        
        // 最终的 Zip 路径
        let zipURL = fileManager.temporaryDirectory.appendingPathComponent("\(rootFolderName).zip")
        
        do {
            // 清理旧文件
            if fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.removeItem(at: rootURL)
            }
            if fileManager.fileExists(atPath: zipURL.path) {
                try fileManager.removeItem(at: zipURL)
            }
            
            // 创建根目录
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            
            // --- A. 写入 CSV ---
            let bom = "\u{FEFF}"
            let csvString = bom + self.generateCSV()
            let csvURL = rootURL.appendingPathComponent("Transactions.csv")
            try csvString.write(to: csvURL, atomically: true, encoding: .utf8)
            
            // --- B. 写入收据图片 ---
            // 创建 Receipts 子文件夹
            let receiptsDir = rootURL.appendingPathComponent("Receipts")
            try fileManager.createDirectory(at: receiptsDir, withIntermediateDirectories: true)
            
            // 遍历并保存图片
            for (index, transaction) in self.enumerated() {
                if let data = transaction.receiptData {
                    let filename = CSVHelper.receiptFilename(
                        for: transaction.merchant,
                        date: transaction.date,
                        index: index + 1
                    )
                    let fileURL = receiptsDir.appendingPathComponent(filename)
                    try? data.write(to: fileURL)
                }
            }
            
            // --- C. 压缩整个根目录 ---
            // shouldKeepParent: false 表示解压后直接看到 CSV 和 Receipts 文件夹，不用再点一层
            try fileManager.zipItem(at: rootURL, to: zipURL, shouldKeepParent: false)
            
            // 清理临时目录
            try? fileManager.removeItem(at: rootURL)
            
            return zipURL
            
        } catch {
            print("打包导出失败: \(error)")
            return nil
        }
    }
}
