//
//  ReceiptModels.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//

import Foundation
import FoundationModels

// 1. 定义收据结构 (对应 Apple 的 Itinerary)
// ⚠️ 字段顺序是刻意的（照抄型字段在前、判断型字段在后），经真机四探针诊断验证：
// iOS 27 beta 端侧模型按"merchant 打头 + 英文前导语"的旧组合生成时，
// 判断型字段（merchant/totalAmount/currency）会连环 nil；倒序 + 无前导语则全字段正常。
// 同时不要给任何字段加 .anyOf 等约束（旧 beta 端侧约束解码有污染 bug）。
// 详见 Components/LocalModelDiagnostics.swift。
@Generable
struct ReceiptMetadata {
    @Guide(description: "Classify the receipt into one of the categories based on the merchant and items")
    var category: Category?

    @Guide(description: "The last 4 digits of the credit card used.")
    var cardLast4: String?   // ✅ 加上问号

    @Guide(description: "The date of transaction in YYYY-MM-DD format.")
    var dateString: String?  // ✅ 加上问号

    @Guide(description: "The currency code, one of: CNY, USD, HKD, JPY, NZD, TWD, GBP, MOP, EUR.")
    var currency: String?    // ✅ 加上问号

    @Guide(description: "The final paid amount.")
    var totalAmount: Double? // ✅ 加上问号

    @Guide(description: "The name of the store or merchant.")
    var merchant: String?  // ✅ 加上问号
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
