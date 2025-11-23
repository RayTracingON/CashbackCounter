//
//  SampleData.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftData
import SwiftUI

@MainActor
class SampleData {
    static func load(context: ModelContext) { // 不需要 manager 了
        
        // 1. 检查有没有卡，没卡先插卡
        let cardDesc = FetchDescriptor<CreditCard>()
        if let count = try? context.fetchCount(cardDesc), count > 0 {
            print("数据已存在")
            return
        }
        
        // 2. 创建卡片 (颜色用 Hex 字符串)
        let card1 = CreditCard(
            bankName: "招商银行", type: "运通餐饮卡", endNum: "8888",
            colorHexes: ["FF0000", "FFA500"], // 红, 橙
            defaultRate: 0.01, specialRates: [.dining: 0.05, .grocery: 0.03],
            issueRegion: .cn, foreignCurrencyRate: 0.03
        )
        
        let card2 = CreditCard(
            bankName: "HSBC HK",
            type: "Pulse",
            endNum: "4896",
            colorHexes: ["FF0000", "000000"],
            defaultRate: 0.004, // 基础 0.4%
            specialRates: [.dining: 0.094],
            issueRegion: .hk,
            foreignCurrencyRate: 0.044,
        )
    
        
        // 先把卡存进去！
        context.insert(card1)
        context.insert(card2)
        
        // 3. 创建交易 (直接把 card 对象传进去)
        let t1 = Transaction(merchant: "Apple Store", category: .digital, location: .cn, amount: 8999, date: Date(), card: card1)
        let t2 = Transaction(merchant: "星巴克", category: .dining, location: .cn, amount: 38, date: Date(), card: card1)
        let t3 = Transaction(merchant: "Uber", category: .travel, location: .us, amount: 30, date: "2025-11-20".toDate(), card: card2)
        
        context.insert(t1)
        context.insert(t2)
        context.insert(t3)
    }
}
