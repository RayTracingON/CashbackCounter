//
//  CardTemplate.swift
//  CashbackCounter
//

import SwiftUI
import SwiftData

struct CardTemplate: Identifiable, Codable, Hashable {
    static func templateKey(bankName: String, type: String) -> String {
        "\(bankName)-\(type)"
    }
    
    var id: UUID = UUID()
    
    let bankName: String
    let type: String
    let colors: [String]
    let region: Region
    
    let specialRate: [Category: Double]
    var paymentMethodRates: [PaymentMethod: Double] = [:]
    
    var rewardType: RewardType = .cashback
    var pointProgramKey: String? = nil
    
    let defaultRate: Double
    let foreignCurrencyRate: Double?
    var localBaseCap: Double = 0
    var foreignBaseCap: Double = 0
    var categoryCaps: [Category: Double] = [:]
    var paymentCaps: [PaymentMethod: Double] = [:]
    var capPeriod: CapPeriod = .yearly
    var pictureURL: String? = nil
    var memo: String? = nil

    // 双币卡模板字段 (费率按百分数，同 foreignCurrencyRate)
    var secondaryRegion: Region? = nil
    var dualCurrencyMode: DualCurrencyMode? = nil
    var secondaryRate: Double? = nil

    var templateKey: String { Self.templateKey(bankName: bankName, type: type) }

    enum CodingKeys: String, CodingKey {
        case bankName, type, colors, region, specialRate, paymentMethodRates, rewardType, pointProgramKey, defaultRate, foreignCurrencyRate, localBaseCap, foreignBaseCap, categoryCaps, paymentCaps, capPeriod, pictureURL, memo, secondaryRegion, dualCurrencyMode, secondaryRate
    }

    static func pointTemplateKey(bankName: String, pointName: String, currencyCode: Region) -> String {
        let parts = [bankName, pointName, currencyCode.currencyCode]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return parts.joined(separator: "|")
    }

    @discardableResult
    func applyRules(to card: CreditCard, pointMap: [String: Point]) -> Bool {
        var modified = false
        
        if card.bankName != bankName {
            card.bankName = bankName
            modified = true
        }
        if card.type != type {
            card.type = type
            modified = true
        }
        if card.colorHexes != colors {
            card.colorHexes = colors
            modified = true
        }
        if card.issueRegion != region {
            card.issueRegion = region
            modified = true
        }
        
        let newSpecialRates = Dictionary(uniqueKeysWithValues: specialRate.map { ($0.key, $0.value / 100.0) })
        if card.specialRates != newSpecialRates {
            card.specialRates = newSpecialRates
            modified = true
        }
        
        let newPaymentRates = Dictionary(uniqueKeysWithValues: paymentMethodRates.map { ($0.key, $0.value / 100.0) })
        if card.paymentMethodRates != newPaymentRates {
            card.paymentMethodRates = newPaymentRates
            modified = true
        }

        if card.rewardType != rewardType {
            card.rewardType = rewardType
            modified = true
        }
        
        let targetPoint = pointProgramKey.flatMap { pointMap[$0] }
        if card.pointProgram != targetPoint {
            card.pointProgram = targetPoint
            modified = true
        }

        let newDefaultRate = defaultRate / 100.0
        if card.defaultRate != newDefaultRate {
            card.defaultRate = newDefaultRate
            modified = true
        }
        
        let newForeignRate = foreignCurrencyRate.map { $0 / 100.0 }
        if card.foreignCurrencyRate != newForeignRate {
            card.foreignCurrencyRate = newForeignRate
            modified = true
        }
        
        if card.secondaryRegion != secondaryRegion {
            card.secondaryRegion = secondaryRegion
            modified = true
        }
        // 仅双币模板才同步 mode，避免单币卡被无意义地改动
        if secondaryRegion != nil {
            let newMode = dualCurrencyMode ?? .secondaryAsLocal
            if card.dualCurrencyMode != newMode {
                card.dualCurrencyMode = newMode
                modified = true
            }
        }
        let newSecondaryRate = secondaryRate.map { $0 / 100.0 }
        if card.secondaryRate != newSecondaryRate {
            card.secondaryRate = newSecondaryRate
            modified = true
        }

        if card.localBaseCap != localBaseCap {
            card.localBaseCap = localBaseCap
            modified = true
        }
        if card.foreignBaseCap != foreignBaseCap {
            card.foreignBaseCap = foreignBaseCap
            modified = true
        }
        if card.categoryCaps != categoryCaps {
            card.categoryCaps = categoryCaps
            modified = true
        }
        if card.paymentCaps != paymentCaps {
            card.paymentCaps = paymentCaps
            modified = true
        }
        if card.capPeriod != capPeriod {
            card.capPeriod = capPeriod
            modified = true
        }
        if card.templateKey != templateKey {
            card.templateKey = templateKey
            modified = true
        }
        
        if let source = pictureURL, !source.isEmpty {
            if card.cardImageData == nil {
                Task {
                    if let data = await ImageDownloadManager.shared.downloadImageData(from: source) {
                        await MainActor.run {
                            withAnimation {
                                card.cardImageData = data
                            }
                        }
                    }
                }
            }
        }
        
        return modified
    }
}
