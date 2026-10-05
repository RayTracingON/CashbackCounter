//
//  RecognizedAmounts.swift
//  CashbackCounter
//
//  截图 / 短信的识别结果 → 交易的原币金额与入账金额
//

import Foundation

/// 一笔金额连同它的币种（以地区表示）
struct CurrencyAmount: Equatable {
    let amount: Double
    let region: Region
}

/// 同屏两种币种时，云端模型标出的原币一侧（商户收的）和入账一侧（卡扣的）；任一侧都可能缺
struct CurrencyConversion: Equatable {
    var original: CurrencyAmount?
    var billing: CurrencyAmount?
}

/// 拆分金额只用得到卡的这两条规则；抽成协议，单测就不必建 SwiftData 容器
protocol CardBillingRules {
    var issueRegion: Region { get }
    func billingRegion(for location: Region) -> Region
}

extension CreditCard: CardBillingRules {}

/// 识别结果拆成交易的两组金额，与 Transaction 的字段一一对应：
/// amount + location 是原币（消费地），billingAmount + billingRegion 是入账（卡币种）。
struct RecognizedAmounts: Equatable {
    var amount: Double
    var location: Region
    var billingAmount: Double
    var billingRegion: Region
    /// 入账金额是按汇率估算的（屏幕上没有实际入账金额）
    var isBillingEstimated = false

    /// - Parameters:
    ///   - totalAmount, currency: 模型抽出的金额与币种。截图指令要求取屏幕上第一个金额，
    ///     外币消费时那通常是入账金额（银联「-¥7.33（HK$8.60）」里的 ¥7.33）
    ///   - rawText: OCR 全文，模型没标出两侧时用来找屏幕上的另一种币种
    ///   - card: 记入的卡，决定入账币种
    ///   - conversion: 云端模型标出的原币 / 入账两侧（本地模型为 nil）
    ///   - rates: 汇率来源（base 币种 → 各币种汇率），单测注入
    static func resolve(
        totalAmount: Double,
        currency: String?,
        rawText: String,
        card: (any CardBillingRules)?,
        conversion: CurrencyConversion? = nil,
        rates: (String) async -> [String: Double] = { await CurrencyService.getRates(base: $0) }
    ) async -> RecognizedAmounts {
        let total = abs(totalAmount)
        let primary = currency.flatMap(Region.from(currencyText:)).map { CurrencyAmount(amount: total, region: $0) }

        // 1. 屏幕上同时有两种币种：一边原币、一边实际入账，都是现成的数，不用估算
        if let (billingSide, originalSide) = twoCurrencies(primary: primary, conversion: conversion, rawText: rawText) {
            let (original, billing) = split(billingSide, originalSide, card: card)
            return RecognizedAmounts(amount: original.amount, location: original.region,
                                     billingAmount: billing.amount, billingRegion: billing.region)
        }

        // 2. 只有一种币种：它就是原币，入账币种按卡的规则定
        let location = OCRService.resolveRegion(currency: currency, rawText: rawText) ?? card?.issueRegion ?? .cn
        let billingRegion = card?.billingRegion(for: location) ?? location
        guard billingRegion != location else {
            return RecognizedAmounts(amount: total, location: location, billingAmount: total, billingRegion: location)
        }
        // 屏幕上没有入账金额：按汇率估算（与 App 内记账一致）
        if let rate = await rates(location.currencyCode)[billingRegion.currencyCode], rate > 0 {
            return RecognizedAmounts(amount: total, location: location, billingAmount: total * rate,
                                     billingRegion: billingRegion, isBillingEstimated: true)
        }
        // 取不到汇率：按原币如实入账，不拿原币数字冒充卡币种金额
        return RecognizedAmounts(amount: total, location: location, billingAmount: total, billingRegion: location)
    }

    /// 同屏的两种币种，按（看起来是入账，看起来是原币）返回。
    /// 先信云端模型标出的两侧（只标了一侧时，另一侧用模型的主金额补）；
    /// 模型没标出来（本地模型 / 漏标）再从 OCR 全文里找另一种币种。
    /// 两侧币种相同、或同一个数标成两种币种（多半是抄错了）的都不算换汇。
    private static func twoCurrencies(
        primary: CurrencyAmount?,
        conversion: CurrencyConversion?,
        rawText: String
    ) -> (CurrencyAmount, CurrencyAmount)? {
        var candidates: [(CurrencyAmount, CurrencyAmount)] = []
        switch (conversion?.billing, conversion?.original) {
        case let (billing?, original?):
            candidates.append((billing, original))
        case let (billing?, nil):
            if let primary { candidates.append((billing, primary)) }
        case let (nil, original?):
            if let primary { candidates.append((primary, original)) }
        case (nil, nil):
            break
        }
        if let primary, let other = OCRService.otherCurrencyAmount(in: rawText, excluding: primary.region) {
            candidates.append((primary, other))
        }
        return candidates.first { $0.0.region != $0.1.region && $0.0.amount != $0.1.amount }
    }

    /// 两种币种里哪边是原币、哪边是入账：入账币种由卡决定
    private static func split(
        _ primary: CurrencyAmount,
        _ other: CurrencyAmount,
        card: (any CardBillingRules)?
    ) -> (original: CurrencyAmount, billing: CurrencyAmount) {
        // 没卡可参照：信传进来的标注（模型标的入账一侧 / 截图惯例里的首个金额）
        guard let card else { return (other, primary) }
        // 一边在这张卡上恰好入账成另一边的币种：典型的外币消费
        if card.billingRegion(for: other.region) == primary.region { return (other, primary) }
        if card.billingRegion(for: primary.region) == other.region { return (primary, other) }
        // 双币卡直接按某一边的币种入账：那边就是原币兼入账，另一个数只是参考折算
        if card.billingRegion(for: primary.region) == primary.region { return (primary, primary) }
        if card.billingRegion(for: other.region) == other.region { return (other, other) }
        // 都对不上（多半匹配错了卡）：退回传进来的标注
        return (other, primary)
    }
}
