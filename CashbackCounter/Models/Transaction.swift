//
//  Transaction.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
struct Transaction: Identifiable {
    let id = UUID()
    let merchant: String
    let category: Category
    let amount: Double
    let date: Date
    let cardID: UUID
    let location: Region

    
    var color: Color { category.color }
    var dateString: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd" // 你可以改成 "yyyy-MM-dd" 或 "MM月dd日"
            return formatter.string(from: date)
        }
}

enum Region: String, CaseIterable, Codable {
    case cn = "中国大陆"
    case hk = "中国香港"
    case us = "美国"
    case other = "其他地区"
    
    var icon: String {
        switch self {
        case .cn: return "🇨🇳" // 直接用 Emoji，简单明了
        case .hk: return "🇭🇰"
        case .us: return "🇺🇸"
        case .other: return "🌍"
        }
    }
}
