//
//  OCRService.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//
import Vision
import UIKit
import FoundationModels // 引入 AI 框架

struct OCRService {
    
    // 保持 AI 解析器实例
    @MainActor static let aiParser = ReceiptParser()
    
    // 返回值改为 Optional，如果失败就返回 nil
    @MainActor
    static func analyzeImage(_ image: UIImage) async -> ReceiptMetadata? {
        
        // 0. (可选) 先检查设备是否支持 AI，不支持直接返回 nil，省电
        // if !AppleIntelligenceService.checkAvailability() { return nil }
        
        // 1. Vision 提取文字
        let rawText = await recognizeText(from: image)
        if rawText.isEmpty { return nil }
        
        print("OCR 文字提取完成，正在请求 Apple Intelligence...")
        
        // 2. 尝试 AI 分析
        do {
            let metadata = try await aiParser.parse(text: rawText)
            print("✅ AI 分析成功")
            return metadata
        } catch {
            print("❌ AI 分析失败: \(error)")
            // 这里不再做降级处理，直接返回 nil
            return nil
        }
    }
    
    // MARK: - Vision 基础能力 (提取文字)
    // 这部分必须保留，因为大模型目前只吃文字
    static func recognizeText(from image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }
        
        return await withCheckedContinuation { continuation in
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                    continuation.resume(returning: "")
                    return
                }
                // 拼接所有文字
                let fullText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                continuation.resume(returning: fullText)
            }
            // 设为 accurate 保证 AI 读到的字是准的
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US", "ja-JP"]
            try? requestHandler.perform([request])
        }
    }
}
