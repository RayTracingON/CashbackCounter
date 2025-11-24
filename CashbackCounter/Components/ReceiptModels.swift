//
//  ReceiptModels.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//

import Foundation
import FoundationModels

// 1. 定义收据结构 (对应 Apple 的 Itinerary)
@Generable
struct ReceiptMetadata {
    @Guide(description: "The name of the store or merchant.")
    var merchant: String?  // ✅ 加上问号
    
    @Guide(description: "The total amount paid (not contain deduction).")
    var totalAmount: Double? // ✅ 加上问号
    
    @Guide(description: "The currency code (choice from those, CNY, USD, HKD, JPY, NZD, TWD, other).")
    var currency: String?    // ✅ 加上问号
    
    @Guide(description: "The date of transaction in YYYY-MM-DD format.")
    var dateString: String?  // ✅ 加上问号
    
    @Guide(description: "The city or country of the shop.")
    var location: String?    // ✅ 加上问号
    
    @Guide(description: "The last 4 digits of the credit card used.")
    var cardLast4: String?   // ✅ 加上问号
    
    @Guide(description: "Classify the receipt into one of the categories based on the merchant and items")
    var category: Category?
}
