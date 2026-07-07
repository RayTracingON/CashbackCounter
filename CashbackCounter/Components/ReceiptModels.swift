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
    
    @Guide(description: "The ISO currency code.", .anyOf(["CNY", "USD", "HKD", "JPY", "NZD", "TWD", "GBP", "MOP", "EUR"]))
    var currency: String?    // ✅ 加上问号

    @Guide(description: "The date of transaction in YYYY-MM-DD format.")
    var dateString: String?  // ✅ 加上问号
    
    @Guide(description: "The last 4 digits of the credit card used.")
    var cardLast4: String?   // ✅ 加上问号
    
    @Guide(description: "Classify the receipt into one of the categories based on the merchant and items")
    var category: Category?
}

@Generable
struct SMSMetadata {
    @Guide(description: "The name of the store or merchant.")
    var merchant: String?  // ✅ 加上问号
    
    @Guide(description: "The total amount paid (not contain deduction).")
    var totalAmount: Double? // ✅ 加上问号
    
    @Guide(description: "The currency code (choice from those, CNY, USD, HKD, JPY, NZD, TWD, GBP, MOP, EUR).")
    var currency: String?
    
    @Guide(description: "The last 4 digits of the credit card used.")
    var cardLast4: String?   // ✅ 加上问号
    
    @Guide(description: "Classify the receipt into one of the categories based on the merchant and items")
    var category: Category?
}

@Generable
struct StatementCardMetadata {
    @Guide(description: "The trailing digits of the card number shown on the statement, after any mask like **** or XXXX. Return ALL visible trailing digits exactly as shown (e.g. '71006' not '7100'). Do not truncate.")
    var cardLast4: String?

    @Guide(description: "The card product name or bank name if available.")
    var cardName: String?
}

@Generable
struct StatementTransactionMetadata {
    @Guide(description: "Transaction region, inferred from currency and merchant. Use 'other' for EU/Europe.")
    var region: Region?

    @Guide(description: "Payment: applePay, qrCode, offline, online, pulse, gba.")
    var paymentMethod: PaymentMethod?

    @Guide(description: "Category from merchant context.")
    var category: Category?

    @Guide(description: "Foreign amount before conversion (e.g. 775 in '775.00 X 0.006'). nil if no conversion.")
    var foreignAmount: Double?
}

@Generable
struct StatementRowTransaction {
    @Guide(description: "Date YYYY-MM-DD.")
    var transactionDate: String?

    @Guide(description: "Merchant name.")
    var merchant: String?

    @Guide(description: "Billing amount.")
    var billingAmount: Double?

    @Guide(description: "Foreign amount if conversion shown, else nil.")
    var foreignAmount: Double?

    @Guide(description: "Foreign currency code.")
    var foreignCurrency: String?
}

@Generable
struct StatementRowTransactionList {
    @Guide(description: "Extracted transactions.")
    var transactions: [StatementRowTransaction]
}
