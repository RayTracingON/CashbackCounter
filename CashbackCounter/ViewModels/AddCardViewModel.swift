//
//  AddCardViewModel.swift
//  CashbackCounter
//

import SwiftUI
import SwiftData

@Observable
final class AddCardViewModel {
    // MARK: - Form State
    var bankName: String
    var cardType: String
    var endNum: String
    var memo: String
    var color1: Color
    var color2: Color
    var region: Region
    var capPeriod: CapPeriod
    var defaultRateStr: String
    var foreignRateStr: String
    var cardImageData: Data?

    // 类别加成费率
    var diningRateStr: String = ""
    var groceryRateStr: String = ""
    var travelRateStr: String = ""
    var digitalRateStr: String = ""
    var otherRateStr: String = ""

    // 基础上限
    var localBaseCapStr: String = ""
    var foreignBaseCapStr: String = ""

    // 类别加成上限
    var diningCapStr: String = ""
    var groceryCapStr: String = ""
    var travelCapStr: String = ""
    var digitalCapStr: String = ""
    var otherCapStr: String = ""

    // 还款日
    var repaymentDayStr: String = ""

    // 支付方式
    var paymentMethodRates: [PaymentMethod: Double]
    var paymentCaps: [PaymentMethod: Double]
    var rewardType: RewardType
    var selectedPointID: UUID?
    var showPointLibrary = false
    var showPhotoPicker = false

    // MARK: - Computed Helpers

    var rewardLabel: String {
        rewardType == .points ? "积分" : "返现"
    }

    var capPeriodTitle: String {
        rewardType == .points ? "积分上限周期" : "返现上限周期"
    }

    var baseSectionTitle: String {
        rewardType == .points ? "基础积分 (所有消费)" : "基础返现 (所有消费)"
    }

    var localRateTitle: String {
        rewardType == .points ? "本币积分率 (%)" : "本币返现率 (%)"
    }

    var foreignRateTitle: String {
        rewardType == .points ? "外币积分率 (%)" : "外币返现率 (%)"
    }

    var localCapTitle: String {
        if rewardType == .points {
            return capPeriod == .monthly ? "本币月积分上限" : "本币年积分上限"
        }
        return capPeriod == .monthly ? "本币月上限" : "本币年上限"
    }

    var foreignCapTitle: String {
        if rewardType == .points {
            return capPeriod == .monthly ? "外币月积分上限" : "外币年积分上限"
        }
        return capPeriod == .monthly ? "外币月上限" : "外币年上限"
    }

    var isFormValid: Bool {
        !bankName.isEmpty && !cardType.isEmpty
    }

    // MARK: - Init

    init(cardToEdit: CreditCard? = nil, template: CardTemplate? = nil) {
        if let card = cardToEdit {
            cardImageData = card.cardImageData
            bankName = card.bankName
            cardType = card.type
            endNum = card.endNum
            memo = card.memo
            repaymentDayStr = card.repaymentDay > 0 ? String(card.repaymentDay) : ""

            if card.colors.count >= 2 {
                color1 = card.colors[0]
                color2 = card.colors[1]
            } else {
                color1 = .blue
                color2 = .purple
            }

            region = card.issueRegion
            capPeriod = card.capPeriod
            defaultRateStr = String(card.defaultRate * 100)

            if let foreignRate = card.foreignCurrencyRate {
                foreignRateStr = String(foreignRate * 100)
            } else {
                foreignRateStr = ""
            }

            if let rate = card.specialRates[.dining] { diningRateStr = String(rate * 100) }
            if let rate = card.specialRates[.grocery] { groceryRateStr = String(rate * 100) }
            if let rate = card.specialRates[.travel] { travelRateStr = String(rate * 100) }
            if let rate = card.specialRates[.digital] { digitalRateStr = String(rate * 100) }
            if let rate = card.specialRates[.other] { otherRateStr = String(rate * 100) }

            if card.localBaseCap > 0 { localBaseCapStr = String(format: "%.0f", card.localBaseCap) }
            if card.foreignBaseCap > 0 { foreignBaseCapStr = String(format: "%.0f", card.foreignBaseCap) }

            if let cap = card.categoryCaps[.dining], cap > 0 { diningCapStr = String(format: "%.0f", cap) }
            if let cap = card.categoryCaps[.grocery], cap > 0 { groceryCapStr = String(format: "%.0f", cap) }
            if let cap = card.categoryCaps[.travel], cap > 0 { travelCapStr = String(format: "%.0f", cap) }
            if let cap = card.categoryCaps[.digital], cap > 0 { digitalCapStr = String(format: "%.0f", cap) }
            if let cap = card.categoryCaps[.other], cap > 0 { otherCapStr = String(format: "%.0f", cap) }

            let ratesForUI = card.paymentMethodRates.mapValues { $0 * 100 }
            paymentMethodRates = ratesForUI
            paymentCaps = card.paymentCaps
            rewardType = card.rewardType
            selectedPointID = card.pointProgram?.id

        } else if let template = template {
            bankName = template.bankName
            cardType = template.type
            endNum = "8888"
            memo = template.memo ?? ""
            cardImageData = nil

            if template.localBaseCap > 0 {
                localBaseCapStr = String(format: "%.0f", template.localBaseCap)
            }
            if template.foreignBaseCap > 0 {
                foreignBaseCapStr = String(format: "%.0f", template.foreignBaseCap)
            }

            if template.colors.count >= 2 {
                color1 = Color(hex: template.colors[0])
                color2 = Color(hex: template.colors[1])
            } else {
                color1 = .blue
                color2 = .purple
            }

            if let cap = template.categoryCaps[.dining], cap > 0 { diningCapStr = String(format: "%.0f", cap) }
            if let cap = template.categoryCaps[.grocery], cap > 0 { groceryCapStr = String(format: "%.0f", cap) }
            if let cap = template.categoryCaps[.travel], cap > 0 { travelCapStr = String(format: "%.0f", cap) }
            if let cap = template.categoryCaps[.digital], cap > 0 { digitalCapStr = String(format: "%.0f", cap) }
            if let cap = template.categoryCaps[.other], cap > 0 { otherCapStr = String(format: "%.0f", cap) }

            region = template.region
            capPeriod = template.capPeriod

            let defStr = String(format: "%.1f", template.defaultRate)
            defaultRateStr = defStr.replacingOccurrences(of: ".0", with: "")

            if let fr = template.foreignCurrencyRate {
                let frStr = String(format: "%.1f", fr)
                foreignRateStr = frStr.replacingOccurrences(of: ".0", with: "")
            } else {
                foreignRateStr = ""
            }

            if let dining = template.specialRate[.dining] {
                diningRateStr = String(format: "%.1f", dining).replacingOccurrences(of: ".0", with: "")
            }
            if let grocery = template.specialRate[.grocery] {
                groceryRateStr = String(format: "%.1f", grocery).replacingOccurrences(of: ".0", with: "")
            }
            if let travel = template.specialRate[.travel] {
                travelRateStr = String(format: "%.1f", travel).replacingOccurrences(of: ".0", with: "")
            }
            if let digital = template.specialRate[.digital] {
                digitalRateStr = String(format: "%.1f", digital).replacingOccurrences(of: ".0", with: "")
            }
            if let other = template.specialRate[.other] {
                otherRateStr = String(format: "%.1f", other).replacingOccurrences(of: ".0", with: "")
            }

            paymentMethodRates = template.paymentMethodRates
            paymentCaps = template.paymentCaps
            rewardType = template.rewardType
            selectedPointID = nil

        } else {
            bankName = ""
            cardType = ""
            endNum = ""
            memo = ""
            color1 = .blue
            color2 = .purple
            region = .cn
            capPeriod = .monthly
            defaultRateStr = "1.0"
            foreignRateStr = ""
            cardImageData = nil

            paymentMethodRates = [:]
            paymentCaps = [:]
            rewardType = .cashback
            selectedPointID = nil
        }
    }

    // MARK: - Binding Helpers

    func rateBinding(for method: PaymentMethod) -> Binding<Double> {
        Binding(
            get: { self.paymentMethodRates[method] ?? 0.0 },
            set: { newValue in
                if newValue == 0 {
                    self.paymentMethodRates.removeValue(forKey: method)
                } else {
                    self.paymentMethodRates[method] = newValue
                }
            }
        )
    }

    func capBinding(for method: PaymentMethod) -> Binding<Double> {
        Binding(
            get: { self.paymentCaps[method] ?? 0.0 },
            set: { newValue in
                if newValue == 0 {
                    self.paymentCaps.removeValue(forKey: method)
                } else {
                    self.paymentCaps[method] = newValue
                }
            }
        )
    }

    // MARK: - Save Logic

    func saveCard(cardToEdit: CreditCard?, template: CardTemplate?, points: [Point], context: ModelContext) {
        let defaultRate = (Double(defaultRateStr) ?? 0) / 100.0
        let rDay = Int(repaymentDayStr) ?? 0
        var foreignRate: Double? = nil
        if !foreignRateStr.isEmpty {
            foreignRate = (Double(foreignRateStr) ?? 0) / 100.0
        }

        let c1Hex = color1.toHex() ?? "0000FF"
        let c2Hex = color2.toHex() ?? "000000"

        var specialRates: [Category: Double] = [:]
        if let rate = Double(diningRateStr), rate > 0 { specialRates[.dining] = rate / 100.0 }
        if let rate = Double(groceryRateStr), rate > 0 { specialRates[.grocery] = rate / 100.0 }
        if let rate = Double(travelRateStr), rate > 0 { specialRates[.travel] = rate / 100.0 }
        if let rate = Double(digitalRateStr), rate > 0 { specialRates[.digital] = rate / 100.0 }
        if let rate = Double(otherRateStr), rate > 0 { specialRates[.other] = rate / 100.0 }

        let locBaseCap = Double(localBaseCapStr) ?? 0
        let forBaseCap = Double(foreignBaseCapStr) ?? 0

        var catCaps: [Category: Double] = [:]
        if let cap = Double(diningCapStr), cap > 0 { catCaps[.dining] = cap }
        if let cap = Double(groceryCapStr), cap > 0 { catCaps[.grocery] = cap }
        if let cap = Double(travelCapStr), cap > 0 { catCaps[.travel] = cap }
        if let cap = Double(digitalCapStr), cap > 0 { catCaps[.digital] = cap }
        if let cap = Double(otherCapStr), cap > 0 { catCaps[.other] = cap }

        let finalPaymentRates = paymentMethodRates.mapValues { $0 / 100.0 }
        let finalPaymentCaps = paymentCaps
        let selectedPoint = points.first { $0.id == selectedPointID }
        let resolvedPointProgram = rewardType == .points ? selectedPoint : nil

        if let existingCard = cardToEdit {
            // 通知 identifier 由 bankName/type/endNum 生成，必须在改字段前用旧值取消旧通知
            NotificationManager.shared.cancelNotification(for: existingCard)

            existingCard.bankName = bankName
            existingCard.type = cardType
            existingCard.endNum = endNum
            existingCard.memo = memo
            existingCard.colorHexes = [c1Hex, c2Hex]
            existingCard.defaultRate = defaultRate
            existingCard.issueRegion = region
            existingCard.foreignCurrencyRate = foreignRate
            existingCard.capPeriod = capPeriod
            existingCard.specialRates = specialRates

            existingCard.localBaseCap = locBaseCap
            existingCard.foreignBaseCap = forBaseCap
            existingCard.categoryCaps = catCaps
            existingCard.repaymentDay = rDay

            existingCard.paymentMethodRates = finalPaymentRates
            existingCard.paymentCaps = finalPaymentCaps
            existingCard.cardImageData = cardImageData
            existingCard.rewardType = rewardType
            existingCard.pointProgram = resolvedPointProgram

            NotificationManager.shared.scheduleNotification(for: existingCard)

        } else {
            let newCard = CreditCard(
                bankName: bankName,
                type: cardType,
                endNum: endNum,
                colorHexes: [c1Hex, c2Hex],
                defaultRate: defaultRate,
                specialRates: specialRates,
                issueRegion: region,
                foreignCurrencyRate: foreignRate,
                templateKey: template?.templateKey,

                localBaseCap: locBaseCap,
                foreignBaseCap: forBaseCap,
                categoryCaps: catCaps,
                capPeriod: capPeriod,
                repaymentDay: rDay,
                memo: memo,
                paymentMethodRates: finalPaymentRates,
                paymentCaps: finalPaymentCaps,
                rewardType: rewardType,
                pointProgram: resolvedPointProgram,
                cardImageData: cardImageData
            )
            context.insert(newCard)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationManager.shared.scheduleNotification(for: newCard)
            }
        }
    }

    // MARK: - Point Program Matching

    func matchPointProgram(from points: [Point], template: CardTemplate?) {
        guard selectedPointID == nil, let key = template?.pointProgramKey else { return }
        if let matched = points.first(where: {
            CardTemplate.pointTemplateKey(bankName: $0.bankName, pointName: $0.pointName, currencyCode: $0.valueCurrencyCode) == key
        }) {
            selectedPointID = matched.id
        }
    }
}
