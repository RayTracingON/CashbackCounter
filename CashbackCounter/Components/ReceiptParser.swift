//
//  AppleIntelligenceService.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//

import SwiftUI
import FoundationModels // 👈 引入新框架 (如果是 Beta 版可能是 GenerativeAI 或其他名字)
import Vision

@Generable
enum CurrencyCode: String, CaseIterable {
    case cny = "CNY"
    case usd = "USD"
    case hkd = "HKD"
    case jpy = "JPY"
    case eur = "EUR"
    case other
}

actor AppleIntelligenceService {
    
    // 1. 检查模型是否可用 (参考文档 Check for availability)
    static func checkAvailability() -> Bool {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return true
        case .unavailable(let reason):
            print("AI 不可用: \(reason)")
            return false
        @unknown default:
            return false
        }
    }
    
    // 2. 核心方法：分析文本 (输入 OCR 得到的文字，输出结构化数据)
    static func analyzeReceiptText(_ text: String) async throws -> String {

        
        // B. 创建 Session (参考文档 Create a session)
        let session = LanguageModelSession()
        
        // C. 发送 Prompt (参考文档 Generate a response)
        // 这里我们将 OCR 识别到的一长串文字作为 Prompt 发送
        let prompt = "Analyze this receipt text:\n\(text)"
        
        // 文档提到可能需要几秒钟，所以是 await
        let response = try await session.respond(to: prompt)
        
        return response.content
    }
}
