//
//  Region.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//

import FoundationModels

enum Region: String, CaseIterable, Codable {
    case cn = "中国大陆"
    case hk = "中国香港"
    case us = "美国"
    case jp = "日本"
    case nz = "新西兰"
    case tw = "台湾"
    case other = "其他地区"
    
    var icon: String {
        switch self {
        case .cn: return "🇨🇳" // 直接用 Emoji，简单明了
        case .hk: return "🇭🇰"
        case .us: return "🇺🇸"
        case .jp: return "🇯🇵"
        case .nz: return "🇳🇿"
        case .tw: return "🇹🇼"
        case .other: return "🌍"
        }
    }
    var currencySymbol: String {
        switch self {
        case .cn: return "CN¥"
        case .hk: return "HK$"
        case .us: return "US$"
        case .jp: return "JP¥"
        case .nz: return "NZ$"
        case .tw: return "NT$"
        case .other: return "€" // 或者用通用符号 ¤
        }
    }
}
