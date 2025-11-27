//
//  CSVHelper.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/25/25.
//

import Foundation
import SwiftUI

extension Array where Element == Transaction {
    
    // 生成 CSV 文本内容
    func generateCSV() -> String {
        // 1. 表头 (Excel 的第一行)
        var csvString = "交易时间,商户名称,消费类别,消费金额(原币),入账金额(本币),返现金额(本币),支付卡片,卡片尾号,消费地区\n"
        
        // 2. 遍历每一行数据
        for t in self {
            let date = t.dateString
            // 处理可能包含逗号的文字 (加引号防止 Excel 格式错乱)
            let merchant = "\"\(t.merchant)\""
            let category = t.category.displayName
            let amount = String(format: "%.2f", t.amount)
            // 假设我们想导出入账金额
            let billing = String(format: "%.2f", t.billingAmount)
            let cashback = String(format: "%.2f", t.cashbackamount)
            let cardNumber = t.card?.endNum ?? "无卡"
            let cardName = t.card != nil ? "\"\(t.card!.bankName) \(t.card!.type)\"" : "已删除卡片"
            let region = t.location.rawValue
            
            // 拼接到 CSV
            let row = "\(date),\(merchant),\(category),\(amount),\(billing),\(cashback),\(cardName),\(cardNumber),\(region)\n"
            csvString.append(row)
        }
        
        return csvString
    }
    
    // 生成临时的 CSV 文件 URL (用于分享)
        func exportCSVFile() -> URL? {
            // 👇 1. 加上 BOM 头 (关键修改！)
            // \u{FEFF} 是 UTF-8 的 BOM 字符，Excel 看到它就会自动切换到 UTF-8 模式
            let bom = "\u{FEFF}"
            let csvString = bom + self.generateCSV()
            
            // 2. 生成文件名 (保持之前的横杠格式，防止路径错误)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let dateString = formatter.string(from: Date())
            
            let fileName = "Cashback_Export_\(dateString).csv"
            
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            
            do {
                // 3. 写入文件
                try csvString.write(to: tempURL, atomically: true, encoding: .utf8)
                return tempURL
            } catch {
                print("CSV 生成失败: \(error)")
                return nil
            }
        }
}
