//
//  OCRService.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 11/24/25.
//

import Vision
import UIKit
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

    /// OCR 识别语言：中英日繁全开，覆盖国内支付截图、日本小票、港台单据
    nonisolated static let defaultLanguages = ["zh-Hans", "en-US", "ja-JP", "zh-Hant"]

    // MARK: - 🚀 总入口：云端多模态优先，否则 OCR + 一次 AI 文本解析
    @MainActor
    static func analyzeImage(_ image: UIImage) async -> ReceiptMetadata? {

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

        let ocrStart = Date()
        let rawText = await recognizeTextInRows(from: image)
        print("⏱️ OCR 耗时: \(String(format: "%.2f", Date().timeIntervalSince(ocrStart)))s")
        print(rawText)

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
        if result.dateString == nil, let date = fallbackDate(from: rawText) {
            print("🧰 日期兜底命中: \(date)")
            result.dateString = date
        }
        return result
    }

    /// 日期兜底：从文本里正则找第一个完整日期，统一成 YYYY-MM-DD
    static func fallbackDate(from text: String) -> String? {
        let patterns = [
            "(20\\d{2})-(\\d{1,2})-(\\d{1,2})",
            "(20\\d{2})年(\\d{1,2})月(\\d{1,2})日",
            "(20\\d{2})/(\\d{1,2})/(\\d{1,2})",
            "(20\\d{2})\\.(\\d{1,2})\\.(\\d{1,2})"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
            if let year = group(1), let monthText = group(2), let dayText = group(3),
               let month = Int(monthText), let day = Int(dayText),
               (1...12).contains(month), (1...31).contains(day) {
                return String(format: "%@-%02d-%02d", year, month, day)
            }
        }
        return nil
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
    
    // MARK: - 🌍 交易地区
    /// 以模型给出的币种为准——币种和金额出自同一次抽取，说的是同一个数；
    /// 模型没给出可识别的币种时才用全文关键词推断。
    /// ⚠️ 不能反过来让关键词推翻模型：中文界面的支付截图里处处是「交易 / 金额」，
    /// 那只说明 App 界面是中文，不代表消费币种——日本消费的截图曾因此被记成中国大陆。
    /// 本地小模型「见 ¥ 就猜 JPY」的老毛病在 ReceiptParser 的本地分支里单独纠正。
    static func resolveRegion(currency: String?, rawText: String) -> Region? {
        if let currency, let region = Region.from(currencyText: currency) { return region }
        return simpleInferRegion(from: rawText)
    }

    // MARK: - 🕵️‍♂️ 本地侦探：根据文字猜地区
    // 这是一个纯字符串匹配方法，速度极快
    static func simpleInferRegion(from text: String) -> Region? {
        let upperText = text.uppercased()

        // 1. 强特征：明确的币种标记（ISO 代码 / 带地区前缀的符号 / 中文币种名），按固定优先级取第一个
        let markerPriority: [Region] = [.jp, .hk, .tw, .nz, .cn, .us, .mo, .other, .uk]
        if let region = markerPriority.first(where: { $0.hasCurrencyMarker(in: upperText) }) {
            return region
        }

        // 2. 弱特征：看文字和地名 (如果货币没找到)
        // 假名是日文独有的；中文界面里显示日本商户名（コーナン）时也能据此认出日本
        if containsJapaneseKana(text) { return .jp }
        if upperText.contains("HONG KONG") { return .hk }
        if Region.containsMarker("TAIPEI", in: upperText) || text.contains("台灣") { return .tw }
        if Region.containsMarker("MACAU", in: upperText) || Region.containsMarker("MACAO", in: upperText) { return .mo }
        if Region.containsMarker("USA", in: upperText) { return .us }
        if Region.containsMarker("UK", in: upperText) { return .uk }
        // 合計 港台繁体也用，必须排在港台地名之后
        if text.contains("合計") || text.contains("料金") { return .jp }

        // 3. 简体界面用语：只说明 App 界面是简体中文，不代表消费币种，所以排最后
        // (¥ 比较难办，中日都用，不单独作为依据)
        if text.contains("金额") || text.contains("交易") { return .cn }

        return nil
    }

    /// 是否含日文假名（平假名 / 片假名 / 半角片假名）。
    /// 刻意不算长音符 ー 和中点 ・：中文文本偶尔也会出现这两个符号。
    static func containsJapaneseKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3041...0x3096, 0x30A1...0x30FA, 0xFF66...0xFF9D: return true
            default: return false
            }
        }
    }

    /// 文本里有没有任何指向日本的迹象：日元标记、假名、日文常用词
    static func hasJapaneseEvidence(in text: String) -> Bool {
        Region.jp.hasCurrencyMarker(in: text.uppercased())
            || containsJapaneseKana(text)
            || text.contains("合計") || text.contains("料金")
    }

    /// 文本里有没有指向中国大陆的迹象：人民币标记，或简体界面用语「金额 / 交易」
    static func hasMainlandEvidence(in text: String) -> Bool {
        Region.cn.hasCurrencyMarker(in: text.uppercased())
            || text.contains("金额") || text.contains("交易")
    }

    // MARK: - 💱 同屏的第二种币种
    /// 外币消费时 App 常同屏显示入账金额和原币金额（银联「-¥7.33（HK$8.60）」、
    /// 银行 App「交易金额 HKD 8.60 / 入账金额 人民币 7.33」）。这里找紧挨着明确币种标记、
    /// 且币种不是 excluded 的那个数。汇率行（含「汇率 / RATE」）整行跳过，紧挨「=」的数也不算；
    /// 出现两种以上外币有歧义，返回 nil；同一外币有多个金额时取出现次数最多的，并列取先出现的。
    static func otherCurrencyAmount(in text: String, excluding excluded: Region) -> CurrencyAmount? {
        var found: [CurrencyAmount] = []
        for line in text.components(separatedBy: .newlines) {
            let upper = line.uppercased()
            if upper.contains("汇率") || upper.contains("匯率") || Region.containsMarker("RATE", in: upper) { continue }
            var hits: [(offset: Int, value: CurrencyAmount)] = []
            for region in Region.allCases where region != excluded {
                for marker in region.currencyMarkers {
                    hits += amounts(adjacentTo: marker, in: upper).map {
                        (offset: $0.offset, value: CurrencyAmount(amount: $0.amount, region: region))
                    }
                }
            }
            found += hits.sorted { $0.offset < $1.offset }.map(\.value)
        }
        guard let region = found.first?.region, found.allSatisfy({ $0.region == region }) else { return nil }
        let counts = Dictionary(found.map { ($0.amount, 1) }, uniquingKeysWith: +)
        return found.max { counts[$0.amount, default: 0] < counts[$1.amount, default: 0] }
    }

    /// 紧挨着币种标记的金额：标记在前（HK$8.60、港币：8.60）或在后（8.60 HKD、10,780日元）。
    /// 前后紧挨「=」的是汇率写法（1HK$=0.85元），不算。upperText 需已转大写。
    private static func amounts(adjacentTo marker: String, in upperText: String) -> [(offset: Int, amount: Double)] {
        let escaped = NSRegularExpression.escapedPattern(for: marker)
        let isWord = Region.isWordMarker(marker)
        let number = "([0-9][0-9,，]*(?:\\.[0-9]+)?)"
        let patterns = [
            (isWord ? "(?<![A-Z])" : "") + escaped + "[\\s:：]*" + number,
            number + "\\s*" + escaped + (isWord ? "(?![A-Z])" : "")
        ]
        let text = upperText as NSString
        var results: [(offset: Int, amount: Double)] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: upperText, range: NSRange(location: 0, length: text.length)) {
                let before = text.substring(to: match.range.location).trimmingCharacters(in: .whitespaces).last
                let after = text.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespaces).first
                if before == "=" || before == "＝" || after == "=" || after == "＝" { continue }
                let digits = text.substring(with: match.range(at: 1))
                    .replacingOccurrences(of: ",", with: "")
                    .replacingOccurrences(of: "，", with: "")
                guard let amount = Double(digits), amount > 0 else { continue }
                results.append((offset: match.range.location, amount: amount))
            }
        }
        return results
    }
    
    // MARK: - Vision 基础能力
    static func recognizeTextInRows(from image: UIImage, languages: [String] = defaultLanguages) async -> String {
        let observations = await recognizeObservations(from: image, languages: languages)
        let rows = reconstructRows(from: observations)
        return rows.map { $0.text }.joined(separator: "\n")
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
    /// nonisolated：OCR 在后台 detached task 里调用它（UIGraphicsImageRenderer 线程安全）
    nonisolated static func downscaledCGImage(_ cgImage: CGImage, maxDimension: CGFloat) -> CGImage {
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
}
