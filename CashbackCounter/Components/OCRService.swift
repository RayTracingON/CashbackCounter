//
//  OCRService.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//

import Vision
import UIKit
import FoundationModels // 引入 AI 框架
import ImageIO          // 用于处理图片方向

struct RecognizedElement: Hashable {
    let text: String
    let xPosition: CGFloat
    let boundingBox: CGRect
}

struct RecognizedRow: Hashable {
    let yPosition: CGFloat
    let elements: [RecognizedElement]

    var text: String {
        elements.map(\.text).joined(separator: " ")
    }
}

struct OCRService {
    
    @MainActor static let aiParser = ReceiptParser()
    
    // MARK: - 🚀 总入口：智能双重分析 (节省一次 AI 调用版)
    @MainActor
    static func analyzeImage(_ image: UIImage, region: Region? = nil) async -> ReceiptMetadata? {

        // ⏱️ 预热模型：趁 OCR 跑的时候把模型权重加载进内存，缩短首次 AI 调用延迟
        aiParser.prewarm()

        // 🟢 情况 A：用户已经在界面上选好了地区 (比如手动选了日本)
        // 直接用该地区的优化语言进行一次精准识别，省流且快。
        if let userRegion = region {
            print("🎯 用户已指定地区: \(userRegion.rawValue)，直接进行精准识别")
            let ocrStart = Date()
            let rawText = await recognizeTextInRows(from: image, languages: getLanguages(for: userRegion))
            print("⏱️ OCR 耗时: \(String(format: "%.2f", Date().timeIntervalSince(ocrStart)))s")
            return await parseWithLogging(rawText)
        }

        // 🟠 情况 B：用户没选地区 (默认模式) -> 启动“本地推断 + 单次高精度扫描”策略
        print("🔍 未指定地区，启动通用探索模式...")

        // 1. OCR：使用通用语言列表
        let broadLanguages = ["zh-Hans", "en-US", "ja-JP", "zh-Hant"]
        let ocrStart = Date()
        let rawText = await recognizeTextInRows(from: image, languages: broadLanguages)
        print("⏱️ OCR 耗时: \(String(format: "%.2f", Date().timeIntervalSince(ocrStart)))s")
        print(rawText)

        // 2. ⚡️ 本地快速推断 (辅助诊断信息，已移除多余的第二轮 OCR)
        let detectedRegion = simpleInferRegion(from: rawText)
        print("⚡️ 本地推断地区: \(detectedRegion?.rawValue ?? "未知")")

        // 3. 最终只调用一次 AI
        print("🤖以此文本请求 AI 分析...")
        return await parseWithLogging(rawText)
    }

    // AI 解析失败时保留原因（模型不可用 / 超出上下文 / 安全拦截），不再被 try? 吞掉
    @MainActor
    private static func parseWithLogging(_ rawText: String) async -> ReceiptMetadata? {
        do {
            let aiStart = Date()
            let result = try await aiParser.parse(text: rawText)
            print("⏱️ AI 解析耗时: \(String(format: "%.2f", Date().timeIntervalSince(aiStart)))s")
            return result
        } catch {
            print("❌ AI 解析失败: \(error)")
            return nil
        }
    }

    /// 供 UI 在进入记账界面时提前调用：用户挑选照片期间即可完成模型加载
    @MainActor
    static func prewarmAI() {
        aiParser.prewarm()
    }
    
    // MARK: - 🕵️‍♂️ 本地侦探：根据文字猜地区
    // 这是一个纯字符串匹配方法，速度极快
    static func simpleInferRegion(from text: String) -> Region? {
        let upperText = text.uppercased()
        
        // 1. 强特征：直接看货币代码 (ISO Code)
        if upperText.contains("JPY") || text.contains("円") { return .jp }
        if upperText.contains("HKD") || text.contains("HK$") { return .hk }
        if upperText.contains("TWD") || upperText.contains("NT$") { return .tw }
        if upperText.contains("NZD") { return .nz }
        if upperText.contains("CN¥") || upperText.contains("RMB") || text.contains("人民币"){ return .cn }
        if upperText.contains("USD") { return .us }
        if upperText.contains("MOP") || upperText.contains("MACAU") { return .mo }
        if upperText.contains("EUR") || upperText.contains("EURO") || upperText.contains("€"){ return .other }
        if upperText.contains("GBP") || upperText.contains("UK") || upperText.contains("£") { return .uk }
        
        // 2. 弱特征：看地名或特殊符号 (如果货币没找到)
        if upperText.contains("合計") || upperText.contains("料金") { return .jp }
        if upperText.contains("HONG KONG") { return .hk }
        if upperText.contains("TAIPEI") || text.contains("台灣") { return .tw }
        if upperText.contains("USA") || upperText.contains("US$") { return .us }
        
        // 3. 符号特征 (¥ 比较难办，中日都用，默认不处理或按概率给一个)
        if text.contains("金额") || text.contains("交易") { return .cn }
        
        return nil
    }
    
    // 获取各地区的最佳语言优先级
    static func getLanguages(for region: Region) -> [String] {
        switch region {
        case .jp:
            // 日本：必须把 ja-JP 放第一
            return ["ja-JP", "en-US", "zh-Hans"]
        case .cn:
            // 简中区
            return ["zh-Hans", "en-US", "ja-JP"]
        case .hk, .tw, .mo:
            // 繁中区
            return ["zh-Hant", "en-US", "ja-JP"]
        case .us, .nz, .other, .uk:
            // 英语区
            return ["en-US", "zh-Hans", "ja-JP"]
        }
    }
    
    // MARK: - Vision 基础能力 (不变)
    static func recognizeTextInRows(from image: UIImage, languages: [String]) async -> String {
        let observations = await recognizeObservations(from: image, languages: languages)
        let rows = reconstructRows(from: observations)
        return rows.map { $0.text }.joined(separator: "\n")
    }
    
    static func recognizeText(from image: UIImage, languages: [String]) async -> String {
        guard let cgImage = image.cgImage else { return "" }
        let orientation = cgImageOrientation(from: image.imageOrientation)
        
        return await withCheckedContinuation { continuation in
            Task.detached {
                let requestHandler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
                let request = VNRecognizeTextRequest { request, error in
                    guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                        continuation.resume(returning: "")
                        return
                    }
                    let fullText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    continuation.resume(returning: fullText)
                }
                request.recognitionLevel = .accurate
                if let supported = try? request.supportedRecognitionLanguages() {
                    request.recognitionLanguages = languages.filter { supported.contains($0) }
                } else {
                    request.recognitionLanguages = languages
                }
                do {
                    try requestHandler.perform([request])
                } catch {
                    print("Vision OCR 错误: \(error)")
                    continuation.resume(returning: "")
                }
            }
        }
    }

    static func recognizeObservations(from image: UIImage, languages: [String]) async -> [VNRecognizedTextObservation] {
        guard let originalImage = image.cgImage else { return [] }
        let orientation = cgImageOrientation(from: image.imageOrientation)


        return await withCheckedContinuation { continuation in
                Task.detached {
                    // 📐 相机原图动辄 4000px+，先缩到 2500px 以内：OCR 速度可提升数倍，精度几乎无损
                    let cgImage = downscaledCGImage(originalImage, maxDimension: 2500)
                    let requestHandler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
                    let request = VNRecognizeTextRequest { request, error in
                        guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                            continuation.resume(returning: [])
                            return
                        }
                        continuation.resume(returning: observations)
                    }
                    request.recognitionLevel = .accurate
                    if let supported = try? request.supportedRecognitionLanguages() {
                        request.recognitionLanguages = languages.filter { supported.contains($0) }
                    } else {
                        request.recognitionLanguages = languages
                    }
                    do {
                        try requestHandler.perform([request])
                    } catch {
                        print("Vision OCR 错误: \(error)")
                        continuation.resume(returning: [])
                    }
                }
            }
        
    }

    static func reconstructRows(from observations: [VNRecognizedTextObservation]) -> [RecognizedRow] {
        let elements: [RecognizedElement] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return RecognizedElement(text: text, xPosition: box.midX, boundingBox: box)
        }

        guard !elements.isEmpty else { return [] }

        let heights = elements.map { $0.boundingBox.height }.sorted()
        let medianHeight = heights[heights.count / 2]
        let rowThreshold = medianHeight * 0.6

        let sortedElements = elements.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [RecognizedRow] = []
        var currentRow: [RecognizedElement] = []
        var lastY: CGFloat?
        var lastHeight: CGFloat?

        for element in sortedElements {
            let elementHeight = element.boundingBox.height
            let localThreshold = min(rowThreshold, min(elementHeight, lastHeight ?? elementHeight) * 0.8)
            if let lastY, abs(element.boundingBox.midY - lastY) < localThreshold {
                currentRow.append(element)
            } else {
                if !currentRow.isEmpty {
                    rows.append(buildRow(from: currentRow))
                }
                currentRow = [element]
            }
            lastY = element.boundingBox.midY
            lastHeight = elementHeight
        }

        if !currentRow.isEmpty {
            rows.append(buildRow(from: currentRow))
        }

        return splitRowsIfNeeded(rows, baselineHeight: medianHeight)
    }
    
    /// 超过 maxDimension 的图片等比缩小；小图原样返回。
    /// 只缩像素不动方向信息，调用方传入的 orientation 依然有效。
    static func downscaledCGImage(_ cgImage: CGImage, maxDimension: CGFloat) -> CGImage {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let maxSide = max(width, height)
        guard maxSide > maxDimension else { return cgImage }

        let scale = maxDimension / maxSide
        let targetSize = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.cgImage ?? cgImage
    }

    static func cgImageOrientation(from uiOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch uiOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private static func buildRow(from elements: [RecognizedElement]) -> RecognizedRow {
        let sorted = elements.sorted { $0.xPosition < $1.xPosition }
        let avgY = sorted.reduce(CGFloat.zero) { $0 + $1.boundingBox.midY } / CGFloat(sorted.count)
        return RecognizedRow(yPosition: avgY, elements: sorted)
    }

    private static func splitRowsIfNeeded(_ rows: [RecognizedRow], baselineHeight: CGFloat) -> [RecognizedRow] {
        let splitThreshold = baselineHeight * 1.1
        let clusterThreshold = baselineHeight * 0.4
        var output: [RecognizedRow] = []

        for row in rows {
            let elements = row.elements
            guard elements.count > 1 else {
                output.append(row)
                continue
            }

            let minY = elements.map { $0.boundingBox.minY }.min() ?? 0
            let maxY = elements.map { $0.boundingBox.maxY }.max() ?? 0
            if (maxY - minY) <= splitThreshold {
                output.append(row)
                continue
            }

            let sortedByY = elements.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            var current: [RecognizedElement] = []
            var lastY: CGFloat?

            for element in sortedByY {
                if let lastY, abs(element.boundingBox.midY - lastY) < clusterThreshold {
                    current.append(element)
                } else {
                    if !current.isEmpty {
                        output.append(buildRow(from: current))
                    }
                    current = [element]
                }
                lastY = element.boundingBox.midY
            }

            if !current.isEmpty {
                output.append(buildRow(from: current))
            }
        }

        return output
    }
    
    // MARK: - 🌟 iOS 18 / macOS 15 Native Table Extraction
    @available(macOS 26.0, iOS 26.0, *)
    static func extractDocumentLayout(from image: UIImage) async throws -> (tables: String, text: String) {
        guard let cgImage = image.cgImage else { return ("", "") }
        
        let request = RecognizeDocumentsRequest()
        let results = try await request.perform(on: cgImage)
        
        var tablesString = ""
        var fullText = ""
        
        for obs in results {
            fullText += obs.document.text.transcript + "\n"
            
            for table in obs.document.tables {
                for row in table.rows {
                    let rowTexts = row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ") }
                    tablesString += "| " + rowTexts.joined(separator: " | ") + " |\n"
                }
                tablesString += "\n"
            }
        }
        
        return (tablesString, fullText)
    }
}
