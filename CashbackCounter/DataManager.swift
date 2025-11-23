//
//  DataManager.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI
import Combine

// 1. 必须是用 class (类)，因为数据要是共享的引用
// 2. 必须遵守 ObservableObject 协议，这样 View 才能监听它的变化
class DataManager: ObservableObject {
    
    // @Published 的意思是：
    // "只要这个数组一变，所有用到了它的界面，统统自动刷新！"
    @Published var cards: [CreditCard] = [
        // 卡片 1
        CreditCard(
            bankName: "HSBC HK",
            type: "Pulse",
            endNum: "4896",
            colors: [.red, .black],
            issueRegion: .hk,
            foreignCurrencyRate: 0.044,
            defaultRate: 0.004, // 基础 0.4%
            specialRates: [.dining: 0.094]
        ),
        
        // 卡片 2
        CreditCard(
            bankName: "农业银行",
            type: "Visa精粹白",
            endNum: "2723",
            colors: [.white, .blue],
            issueRegion: .cn,
            foreignCurrencyRate: 0.03,
            defaultRate: 0, // 基础 0%
            specialRates: [:]
        ),
        
        // 卡片 3
        CreditCard(
            bankName: "HSBC US",
            type: "Elite Master",
            endNum: "0444",
            colors: [.black, .white],
            issueRegion: .us,
            foreignCurrencyRate: 0.013,
            defaultRate: 0.013, 
            specialRates: [.travel:0.069,.dining:0.027]
        )
        
    ]
    @Published var transactions: [Transaction] = []
    init() {
            // 造假数据：使用第一张卡 (cards[0]) 和 第二张卡 (cards[1])
            // 确保 cards 数组不为空
            transactions = [
                Transaction(merchant: "Apple Store", category: .digital, amount: 8999, date: Date(), cardID: cards[0].id, location: .cn),
                Transaction(merchant: "星巴克", category: .dining, amount: 38, date: Date(), cardID: cards[0].id, location: .cn),
                    Transaction(merchant: "滴滴出行", category: .travel, amount: 56, date: "2025-11-20".toDate(), cardID: cards[1].id, location: .cn),
                    Transaction(merchant: "CDF", category: .other, amount: 56, date: "2025-11-20".toDate(), cardID: cards[0].id, location: .cn),
                    Transaction(merchant: "Uber", category: .travel, amount: 56, date: "2025-11-20".toDate(), cardID: cards[1].id, location: .us)
                ]
        }
    
    // 添加交易
    func addTransaction(merchant: String, amount: Double, category: Category, date: Date, card: CreditCard, region: Region) {
            let newTransaction = Transaction(
                merchant: merchant,
                category: category,
                amount: amount,
                date: date,
                cardID: card.id,
                location: region
            )
            transactions.insert(newTransaction, at: 0)
        }
    // 查询返现
    func getCashback(for transaction: Transaction) -> Double {
            guard let card = cards.first(where: { $0.id == transaction.cardID }) else { return 0.0 }
            
            // 👇 传 location 进去判断
            let rate = card.getRate(
                for: transaction.category,
                location: transaction.location
            )
            
            return transaction.amount * rate
        }
}

extension String {
    func toDate() -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd" // 必须按照这个格式写
        return formatter.date(from: self) ?? Date() // 如果格式错了，默认返回今天
    }
}

