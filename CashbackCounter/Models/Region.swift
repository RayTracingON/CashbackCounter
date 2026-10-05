//
//  Region.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//

import Foundation
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

    /// 把模型输出的币种文本映射到地区：ISO 代码、带地区前缀的符号（HK$、JP¥）、中文币种名（日元）都认。
    /// 同时出现多个地区的标记（"JPY/CNY"）或只有裸 ¥ / $ 时有歧义，返回 nil 交给调用方兜底。
    static func from(currencyText: String) -> Region? {
        let upper = currencyText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let exact = from(currencyCode: upper) { return exact }
        let matches = allCases.filter { $0.hasCurrencyMarker(in: upper) }
        return matches.count == 1 ? matches.first : nil
    }

    /// 明确指向本币种的文本标记：ISO 代码、带地区前缀的符号、中文币种名。
    /// 裸 ¥（中日共用）和裸 $（多地共用）有歧义，刻意不收录。
    var currencyMarkers: [String] {
        switch self {
        case .cn:    return ["CNY", "RMB", "CN¥", "人民币", "人民幣"]
        case .jp:    return ["JPY", "YEN", "JP¥", "円", "日元", "日圆", "日圓"]
        case .hk:    return ["HKD", "HK$", "港币", "港幣", "港元"]
        case .us:    return ["USD", "US$", "美元"]
        case .tw:    return ["TWD", "NT$", "台币", "台幣"]
        case .nz:    return ["NZD", "NZ$", "纽币", "紐幣"]
        case .mo:    return ["MOP", "澳门元", "澳門元", "澳门币", "澳門幣"]
        case .uk:    return ["GBP", "£", "英镑", "英鎊"]
        case .other: return ["EUR", "EURO", "€", "欧元", "歐元"]
        }
    }

    /// upperText（需已转大写）里是否出现本币种的明确标记
    func hasCurrencyMarker(in upperText: String) -> Bool {
        currencyMarkers.contains { Self.containsMarker($0, in: upperText) }
    }

    /// 英文标记按「前后都不是字母」整词匹配，避免 IKEBUKURO / FUKUOKA 里的 UK、
    /// MUSASHINO 里的 USA、AMATEUR 里的 EUR 这类子串误命中；紧贴数字（JPY10780）照样算。
    /// 中文和符号标记没有这个问题，直接包含即可。
    static func containsMarker(_ marker: String, in upperText: String) -> Bool {
        guard let first = marker.unicodeScalars.first,
              first.isASCII, CharacterSet.letters.contains(first) else {
            return upperText.contains(marker)
        }
        let pattern = "(?<![A-Z])\(NSRegularExpression.escapedPattern(for: marker))(?![A-Z])"
        return upperText.range(of: pattern, options: .regularExpression) != nil
    }
}
