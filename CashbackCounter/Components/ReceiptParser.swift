//
//  AppleIntelligenceService.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//
import FoundationModels
import Observation // 苹果的新状态管理框架
import Foundation


@MainActor
@Observable
final class ReceiptParser {
    
    // 1. 这里的 session 定义和苹果一模一样
    private let session: LanguageModelSession
    
    init() {
        // 2. 使用苹果风格的 Instructions 构建器
        self.session = LanguageModelSession(
            instructions: Instructions {
                "You are an expert receipt data extractor."
                
                "Your job is to analyze the OCR text and extract key details into a JSON structure."
                "CRITICAL RULES FOR AMOUNT extraction:"
                // 1. 告诉它找“实付”
                "- You must extract the FINAL PAID amount (实付金额/合计/Total)."
                // 2. 明确告诉它不要自己做加法，也不要拿原价
                "- If there are discounts (立减/优惠/Discount), DO NOT use the subtotal (原价/小计). Use the final amount AFTER discount."
                "- DO NOT add the discount to the total. DO NOT sum up numbers yourself."
                // 3. 给出关键词提示
                "- Look for keywords like 'Total', 'Grand Total', '实付', '已支付', 'Amount Due'."
                "CRITICAL RULES FOR CATEGORIZATION:"
                "- Analyze the merchant name and items purchased."
                "- 'dining': Restaurants, Cafes, Starbucks, McDonald's, Food delivery."
                "- 'grocery': Supermarkets, 7-Eleven, Convenience stores, Daily necessities."
                "- 'travel': Uber, Taxi, Flights, Hotels, Gas stations, Trains."
                "- 'digital': Electronics, Apple Store, Steam, Software, Games."
                "- 'other': Anything that doesn't fit above."
                
                "Rules:"
                "- Extract exact values for merchant, amount, card ending number, merchant category, and date."
                "- Infer currency from symbols (¥, $) or location."
                "- If a value is missing, leave it nil."
            }
        )
    }
    
    // 3. 解析方法
    func parse(text: String) async throws -> ReceiptMetadata {
        
        // 使用苹果风格的 respond 方法，配合 trailing closure 写 Prompt
        let response = try await session.respond(generating: ReceiptMetadata.self) {
            // 这里是 Prompt 部分
            "Analyze this receipt text:"
            text // 直接放入 OCR 识别出的文字
        }
        
        return response.content
    }
}
