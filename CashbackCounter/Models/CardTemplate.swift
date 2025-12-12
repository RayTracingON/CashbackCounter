//
//  CardTemplate.swift
//  CashbackCounter
//
//  Created by OpenAI Assistant on 2024-05-28.
//

import SwiftUI
import SwiftData

@Model
final class CardTemplate: Identifiable {
    static func templateKey(bankName: String, type: String) -> String {
        "\(bankName)-\(type)"
    }

    @Attribute(.unique) var templateKey: String
    var id: UUID = UUID()
    var bankName: String
    var type: String
    var colors: [String]
    var region: Region
    var specialRate: [Category: Double]
    var defaultRate: Double
    var foreignCurrencyRate: Double?
    var localBaseCap: Double
    var foreignBaseCap: Double
    var categoryCaps: [Category: Double]
    var capPeriod: CapPeriod

    func applyRules(to card: CreditCard) {
        card.bankName = bankName
        card.type = type
        card.colorHexes = colors
        card.issueRegion = region
        card.specialRates = Dictionary(uniqueKeysWithValues: specialRate.map { ($0.key, $0.value / 100.0) })
        card.defaultRate = defaultRate / 100.0
        card.foreignCurrencyRate = foreignCurrencyRate.map { $0 / 100.0 }
        card.localBaseCap = localBaseCap
        card.foreignBaseCap = foreignBaseCap
        card.categoryCaps = categoryCaps
        card.capPeriod = capPeriod
        card.templateKey = templateKey
    }

    init(templateKey: String,
         bankName: String,
         type: String,
         colors: [String],
         region: Region,
         specialRate: [Category: Double],
         defaultRate: Double,
         foreignCurrencyRate: Double?,
         localBaseCap: Double = 0,
         foreignBaseCap: Double = 0,
         categoryCaps: [Category: Double] = [:],
         capPeriod: CapPeriod = .yearly) {
        self.templateKey = templateKey
        self.bankName = bankName
        self.type = type
        self.colors = colors
        self.region = region
        self.specialRate = specialRate
        self.defaultRate = defaultRate
        self.foreignCurrencyRate = foreignCurrencyRate
        self.localBaseCap = localBaseCap
        self.foreignBaseCap = foreignBaseCap
        self.categoryCaps = categoryCaps
        self.capPeriod = capPeriod
    }
}

// MARK: - Seed data
struct CardTemplateSeed {
    let bankName: String
    let type: String
    let colors: [String]
    let region: Region
    let specialRate: [Category: Double]
    let defaultRate: Double
    let foreignCurrencyRate: Double?
    var localBaseCap: Double = 0
    var foreignBaseCap: Double = 0
    var categoryCaps: [Category: Double] = [:]
    var capPeriod: CapPeriod = .yearly

    var templateKey: String { CardTemplate.templateKey(bankName: bankName, type: type) }

    func makeModel() -> CardTemplate {
        CardTemplate(
            templateKey: templateKey,
            bankName: bankName,
            type: type,
            colors: colors,
            region: region,
            specialRate: specialRate,
            defaultRate: defaultRate,
            foreignCurrencyRate: foreignCurrencyRate,
            localBaseCap: localBaseCap,
            foreignBaseCap: foreignBaseCap,
            categoryCaps: categoryCaps,
            capPeriod: capPeriod
        )
    }

    func apply(to template: CardTemplate) {
        template.templateKey = templateKey
        template.bankName = bankName
        template.type = type
        template.colors = colors
        template.region = region
        template.specialRate = specialRate
        template.defaultRate = defaultRate
        template.foreignCurrencyRate = foreignCurrencyRate
        template.localBaseCap = localBaseCap
        template.foreignBaseCap = foreignBaseCap
        template.categoryCaps = categoryCaps
        template.capPeriod = capPeriod
    }
}

extension CardTemplate {
    static let defaultSeeds: [CardTemplateSeed] = [
        CardTemplateSeed(bankName: "滙豐香港", type: "Red信用卡", colors: ["DA291C", "005863"], region: .hk, specialRate: [ : ], defaultRate: 4.0, foreignCurrencyRate: 1.0, localBaseCap: 4800, foreignBaseCap: 0, categoryCaps: [: ]),
        CardTemplateSeed(bankName: "滙豐香港", type: "Pulse銀聯信用卡 ", colors: ["DB0011", "1A1A1A"], region: .cn, specialRate: [ .dining: 5 ], defaultRate: 4.4, foreignCurrencyRate: 2.4, localBaseCap: 4400, foreignBaseCap: 2400, categoryCaps: [.dining: 500]),
        CardTemplateSeed(bankName: "滙豐香港", type: "卓越理財信用卡", colors: ["111111", "D9D9D9"], region: .hk, specialRate: [ : ], defaultRate: 0.4, foreignCurrencyRate: 2.4),
        CardTemplateSeed(bankName: "滙豐香港", type: "Visa Signature卡", colors: ["1C1C1C", "757575"], region: .hk, specialRate: [ : ], defaultRate: 1.6, foreignCurrencyRate: 3.6, foreignBaseCap: 3600),
        CardTemplateSeed(bankName: "滙豐香港", type: "萬事達卡扣賬卡", colors: ["1D5564", "85BDCD"], region: .hk, specialRate: [ : ], defaultRate: 0.4, foreignCurrencyRate: 0.4),
        CardTemplateSeed(bankName: "HSBC US", type: "Elite ", colors: ["050505", "050505"], region: .us, specialRate: [ .travel: 5.28,.dining:1.32], defaultRate: 1.32, foreignCurrencyRate: 1.32),
        CardTemplateSeed(bankName: "工銀亞洲", type: "Visa Signature", colors: ["121212", "EDC457"], region: .hk, specialRate: [ .grocery: 15], defaultRate: 1.5, foreignCurrencyRate: 1.5, categoryCaps: [.grocery: 2400]),
        CardTemplateSeed(bankName: "工銀亞洲", type: "粵港澳灣區信用卡", colors: ["0F0F0F", "C0C0C0"], region: .cn, specialRate: [ .grocery: 15], defaultRate: 1.5, foreignCurrencyRate: 1.5, categoryCaps: [.grocery: 2400]),
        CardTemplateSeed(bankName: "信銀國際", type: "大灣區雙幣信用卡", colors: ["8A8F99", "E3DEE9"], region: .cn, specialRate: [ .other: 6], defaultRate: 4, foreignCurrencyRate: 0.4, localBaseCap: 1800, foreignBaseCap: 0, categoryCaps: [.other: 3000], capPeriod: .monthly),
        CardTemplateSeed(bankName: "中銀香港", type: "萬事達卡扣賬卡", colors: ["121212", "D4B979"], region: .hk, specialRate: [ : ], defaultRate: 0.5, foreignCurrencyRate: 0.5),
        CardTemplateSeed(bankName: "农行", type: "大学生青春卡", colors: ["9EC0B3", "D9A62E"], region: .cn, specialRate: [ : ], defaultRate: 0.1, foreignCurrencyRate: 4),
        CardTemplateSeed(bankName: "农行", type: "Visa尊然白金信用卡", colors: ["1A1A1A", "C4C6C8"], region: .cn, specialRate: [ : ], defaultRate: 0.1, foreignCurrencyRate: 4),
        CardTemplateSeed(bankName: "工行", type: "牡丹祥运信用卡", colors: ["2F2F2F", "C7A04D"], region: .cn, specialRate: [ : ], defaultRate: 0, foreignCurrencyRate: 3)
    ]

    static func syncDefaultTemplates(in context: ModelContext) throws {
        let descriptor = FetchDescriptor<CardTemplate>()
        let currentTemplates = try context.fetch(descriptor)
        let currentMap = Dictionary(uniqueKeysWithValues: currentTemplates.map { ($0.templateKey, $0) })

        for seed in defaultSeeds {
            if let existing = currentMap[seed.templateKey] {
                seed.apply(to: existing)
            } else {
                context.insert(seed.makeModel())
            }
        }
    }

    static func refreshCardsFromTemplates(in context: ModelContext) throws {
        let templates = try context.fetch(FetchDescriptor<CardTemplate>())
        let templateMap = Dictionary(uniqueKeysWithValues: templates.map { ($0.templateKey, $0) })
        let cards = try context.fetch(FetchDescriptor<CreditCard>())

        for card in cards {
            guard let key = card.templateKey, let template = templateMap[key] else { continue }
            template.applyRules(to: card)
        }
    }
}
