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
    
    // MARK: - 导入交易逻辑
    static func parseTransactionCSV(content: String, context: ModelContext, allCards: [CreditCard]) throws {
        let rows = content.components(separatedBy: .newlines)
        
        // 预先准备反查字典，提高匹配效率
        // 把 "餐饮美食" -> .dining
        let categoryMap: [String: Category] = Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0.displayName, $0) })
        // 把 "中国大陆" -> .cn
        let regionMap: [String: Region] = Dictionary(uniqueKeysWithValues: Region.allCases.map { ($0.rawValue, $0) })
        
        for (index, row) in rows.enumerated() {
            // 跳过表头(第0行)和空行
            if index == 0 || row.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            
            // 👇 使用智能分割，处理你导出时加的引号
            let columns = splitCSVLine(row)
            
            // 确保列数足够 (你的 generateCSV 生成了 9 列)
            if columns.count < 9 { continue }
            
            // --- 1. 解析字段 (对应 generateCSV 的顺序) ---
            // 顺序: 0:时间, 1:商户, 2:类别, 3:原币金额, 4:入账金额, 5:返现, 6:卡名, 7:尾号, 8:地区
            
            let dateStr = columns[0]
            // 处理商户名：去掉包裹的引号，并把双引号转义还原 ("" -> ")
            let merchant = cleanCSVField(columns[1])
            let categoryName = columns[2]
            let amount = Double(columns[3]) ?? 0.0
            let billing = Double(columns[4]) ?? 0.0
            let cashback = Double(columns[5]) ?? 0.0
            let cardNameRaw = cleanCSVField(columns[6]) // 去掉卡名的引号
            let cardEndNum = columns[7]
            let regionName = columns[8] // 注意：这里可能带有换行符，需要小心
            
            // --- 2. 类型转换 ---
            let date = dateStr.toDate() // 使用你项目里的 toDate()
            let category = categoryMap[categoryName] ?? .other
            // regionName 可能会带 \r (Windows换行符)，需要 trim 一下
            let cleanRegionName = regionName.trimmingCharacters(in: .whitespacesAndNewlines)
            let region = regionMap[cleanRegionName] ?? .cn
            
            // --- 3. 核心：找回对应的信用卡 ---
            // 逻辑：尝试在 allCards 中找到一张卡，它的 (BankName + Type) 和 尾号 都匹配
            var matchedCard: CreditCard? = nil
            
            if cardEndNum != "无卡" && cardNameRaw != "已删除卡片" {
                // 优先尝试全匹配 (卡名+尾号)
                matchedCard = allCards.first { card in
                    let dbCardName = "\(card.bankName) \(card.type)"
                    return card.endNum == cardEndNum && dbCardName == cardNameRaw
                }
                
                // 如果找不到（可能用户改了卡名），尝试只匹配尾号作为兜底
                if matchedCard == nil {
                    matchedCard = allCards.first { $0.endNum == cardEndNum }
                }
            }
            
            // --- 4. 创建并插入交易 ---
            // 注意：直接使用 CSV 里的 cashbackAmount，保证历史数据一致性
            let newTransaction = Transaction(
                merchant: merchant,
                category: category,
                location: region,
                amount: amount,
                date: date,
                card: matchedCard,
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
    
    // 生成临时的 CSV 文件 URL (用于分享)
    func exportCSVFile() -> URL? {
        // ... (保持你发来的代码不变) ...
        let bom = "\u{FEFF}"
        let csvString = bom + self.generateCSV()
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateString = formatter.string(from: Date())
        
        let fileName = "Cashback_Export_\(dateString).csv"
        
        // ⚠️ 建议：如果你之前遇到过 tmp 目录分享报错的问题
        // 可以改用 .cachesDirectory，不过 .temporaryDirectory 也是标准的做法
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try csvString.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            print("CSV 生成失败: \(error)")
            return nil
        }
    }

    /// 导出带收据图片的压缩包，文件名中会包含交易日期与商户，便于识别。
    /// - Returns: 生成的 zip 文件 URL，如果当前没有收据则返回 nil。
    func exportReceiptsZip() -> URL? {
        // 仅处理包含收据图片的交易
        let transactionsWithReceipts: [(index: Int, transaction: Transaction, data: Data)] =
            self.enumerated().compactMap { index, transaction in
                guard let data = transaction.receiptData else { return nil }
                return (index, transaction, data)
            }

        guard !transactionsWithReceipts.isEmpty else { return nil }

        let fileManager = FileManager.default

        // 生成时间戳，便于区分导出批次
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = timestampFormatter.string(from: Date())

        // 临时收据目录
        let receiptsDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("Cashback_Receipts_\(timestamp)")

        do {
            // 如果目录已存在，先清理
            if fileManager.fileExists(atPath: receiptsDirectory.path) {
                try fileManager.removeItem(at: receiptsDirectory)
            }
            try fileManager.createDirectory(at: receiptsDirectory, withIntermediateDirectories: true)
        } catch {
            print("收据目录创建失败: \(error)")
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"

        // 写入所有收据图片
        for entry in transactionsWithReceipts {
            let transaction = entry.transaction
            let dateString = dateFormatter.string(from: transaction.date)

            // 商户名称用于文件名，移除不安全字符并控制长度
            let sanitizedMerchant = transaction.merchant
                .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

            let merchantComponent: String
            if sanitizedMerchant.isEmpty {
                merchantComponent = "receipt"
            } else {
                let prefix = sanitizedMerchant.prefix(40) // 避免文件名过长
                merchantComponent = String(prefix)
            }

            let filename = "receipt_\(dateString)_\(merchantComponent)_\(entry.index + 1).jpg"
            let fileURL = receiptsDirectory.appendingPathComponent(filename)

            do {
                try entry.data.write(to: fileURL)
            } catch {
                print("写入收据失败: \(error)")
            }
        }

        // 将收据目录压缩为 zip
        let zipURL = fileManager.temporaryDirectory.appendingPathComponent("Cashback_Receipts_\(timestamp).zip")

        do {
            if fileManager.fileExists(atPath: zipURL.path) {
                try fileManager.removeItem(at: zipURL)
            }

            try fileManager.zipItem(at: receiptsDirectory, to: zipURL, shouldKeepParent: false)

            // 清理中间目录
            try fileManager.removeItem(at: receiptsDirectory)
            return zipURL
        } catch {
            print("收据压缩失败: \(error)")
            return nil
        }
    }
}
