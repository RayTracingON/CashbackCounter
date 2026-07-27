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

        // ☁️🖼️ 多模态优先：云端 PCC 就绪时把原图直传模型，跳过本地 OCR。
        // 本地模型跑图片输入过慢，刻意不做本地多模态；云端失败则回退下方 OCR 文本管线。
        if #available(iOS 27.0, *), ReceiptParser.isMultimodalAvailable {
            do {
                let start = Date()
                let result = try await aiParser.parseReceiptImage(image)
                print("⏱️ 云端多模态解析耗时: \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
                return result
            } catch {
                print("❌ 云端多模态解析失败，回退 OCR 文本管线: \(error)")
            }
        }

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
            // 小票路径禁用"首个货币符号金额"兜底：那通常是第一件商品的单价
            return backfill(result, rawText: rawText, allowSymbolFallback: false)
        } catch {
            print("❌ AI 解析失败: \(error)")
            return nil
        }
    }

    // MARK: - 🧰 确定性兜底：模型漏抽字段时用规则补齐
    /// 本地小模型偶发漏抽（返回 nil）；金额和币种可以用纯规则可靠找回。
    /// merchant 不做兜底：OCR 首行常是乱码，宁缺勿错，留给用户手动填。
    static func backfill(_ metadata: ReceiptMetadata, rawText: String, allowSymbolFallback: Bool = true) -> ReceiptMetadata {
        var result = metadata
        if result.totalAmount == nil, let amount = fallbackAmount(from: rawText, allowSymbolFallback: allowSymbolFallback) {
            print("🧰 金额兜底命中: \(amount)")
            result.totalAmount = amount
        }
        if result.currency == nil, let region = simpleInferRegion(from: rawText) {
            print("🧰 币种兜底命中: \(region.currencyCode)")
            result.currency = region.currencyCode
        }
        if result.merchant == nil, let merchant = fallbackMerchant(from: rawText) {
            print("🧰 商户兜底命中: \(merchant)")
            result.merchant = merchant
        }
        return result
    }

    /// 商户兜底：只认带明确标签的行（收款方/商户名称/Merchant 等），取标签后面的文本。
    /// 刻意不做"取首行"式猜测——OCR 首行常是状态栏乱码，宁缺勿错。
    static func fallbackMerchant(from text: String) -> String? {
        let labels = ["收款方", "收款商户", "商户名称", "商户全称", "商戶名稱", "店名", "Merchant"]
        for line in text.components(separatedBy: .newlines) {
            for label in labels {
                guard let range = line.range(of: label, options: .caseInsensitive) else { continue }
                let candidate = line[range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":：|·"))
                    .trimmingCharacters(in: .whitespaces)
                if candidate.count >= 2 { return String(candidate) }
            }
        }
        return nil
    }

    /// 按关键词优先级从文本行里找实付金额。
    /// allowSymbolFallback：关键词都没命中时，是否退而取第一个紧跟货币符号的金额——
    /// 支付截图适用（首个大字金额即实付）；小票不适用（首个 ¥ 金额通常是单品价），传 false。
    static func fallbackAmount(from text: String, allowSymbolFallback: Bool = true) -> Double? {
        let keywords = ["实付", "實付", "已支付", "支付金额", "合計", "合计",
                        "お支払い", "請求金額", "Grand Total", "Amount Due", "Total"]
        let lines = text.components(separatedBy: .newlines)

        for keyword in keywords {
            for line in lines {
                guard line.range(of: keyword, options: .caseInsensitive) != nil else { continue }
                let lower = line.lowercased()
                // 排除小计行（折扣前金额）与数量行（"合計点数 20点"里的 20 不是金额）
                if lower.contains("subtotal") || line.contains("小計") || line.contains("小计") { continue }
                if line.contains("点数") || line.contains("點數") || line.contains("件数") || line.contains("人数") { continue }
                if let amount = firstAmount(in: line) { return amount }
            }
        }

        guard allowSymbolFallback else { return nil }
        // 次选：第一个紧跟货币符号的金额（支付截图的大字金额通常没有关键词前缀）
        for line in lines {
            if let amount = firstAmount(in: line, requireCurrencySymbol: true) { return amount }
        }
        return nil
    }

    private static func firstAmount(in line: String, requireCurrencySymbol: Bool = false) -> Double? {
        let pattern = requireCurrencySymbol
            ? "[¥￥$€£]\\s*([0-9][0-9,，]*(?:\\.[0-9]{1,2})?)"
            : "([0-9][0-9,，]*(?:\\.[0-9]{1,2})?)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let matchRange = Range(match.range(at: 1), in: line) else { return nil }
        let cleaned = line[matchRange]
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
        return Double(cleaned)
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
