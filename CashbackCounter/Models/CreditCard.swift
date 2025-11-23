//
//  CreditCard.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/23/25.
//

import SwiftUI

struct CreditCard: Identifiable {
    let id = UUID()
    let bankName: String
    let type: String
    let endNum: String
    let colors: [Color]
    
    
    // --- 新增的核心逻辑 ---
    // 👇 1. 这张卡的“老家”在哪里？
    let issueRegion: Region
        
    // 👇 2. 如果在“老家”以外的地方刷，返现率是多少？
    let foreignCurrencyRate: Double?
    
    // 1. 保底返现率 (比如 0.01 代表 1%)
    let defaultRate: Double
        
    // 2. 特殊类别返现表 [类别图标名 : 返现率]
    // 比如 ["cart.fill": 0.05] 代表超市返 5%
    let specialRates: [Category: Double]
    
    // 3. 核心计算逻辑升级
    func getRate(for category: Category, location: Region) -> Double {
            // A. 先查类别基础分 (比如餐饮)
            let categoryRate = specialRates[category] ?? defaultRate
            
            // B. 判断是否为跨境交易
            // 如果交易地点 (location) 不等于 卡片发行地 (issueRegion)，就是跨境
            if location != issueRegion {
                // 如果这张卡有境外返现优惠
                if let foreignRate = foreignCurrencyRate {
                    // 取最大值 (比如餐饮 1%，但境外全返 3%，那就按 3% 算)
                    return max(categoryRate, foreignRate)
                }
            }
            
            return categoryRate
        }
}
