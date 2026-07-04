//
//  Region.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//

import FoundationModels

@Generable
enum Region: String, CaseIterable, Codable {
    case cn = "中国大陆"
    case hk = "香港"
    case us = "美国"
    case jp = "日本"
    case nz = "新西兰"
    case tw = "台湾"
    case mo = "澳门"
    case uk = "英国"
    case other = "欧盟"
    
    var icon: String {
        switch self {
        case .cn: return "🇨🇳" // 直接用 Emoji，简单明了
        case .hk: return "🇭🇰"
        case .us: return "🇺🇸"
        case .jp: return "🇯🇵"
        case .nz: return "🇳🇿"
        case .tw: return "🇹🇼"
        case .mo: return "🇲🇴"
        case .uk: return "🇬🇧"
        case .other: return "🇪🇺"
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
        case .mo: return "MO$"
        case .uk: return "GB£"
        case .other: return "EU€" // 或者用通用符号 ¤
        }
    }
    var currencyCode: String {
        switch self {
        case .cn: return "CNY"
        case .us: return "USD"
        case .hk: return "HKD"
        case .jp: return "JPY"
        case .nz: return "NZD"
        case .tw: return "TWD"
        case .mo: return "MOP"
        case .uk: return "GBP"
        case .other: return "EUR"
        }
    }
}

extension Region {
    /// 根据货币代码 (如 "CNY") 反查地区
    static func from(currencyCode: String) -> Region? {
        let code = currencyCode.uppercased()
        return Region.allCases.first { $0.currencyCode == code }
    }
}
