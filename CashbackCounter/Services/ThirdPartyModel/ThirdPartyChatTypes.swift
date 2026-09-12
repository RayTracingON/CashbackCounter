//
//  ThirdPartyChatTypes.swift
//  CashbackCounter
//
//  Transcript ↔ 通用聊天消息的中转层。
//  三家 API 的线上格式各不相同，但都是「system + 多轮 user/assistant + 可能带图」这个形状，
//  所以先把 FoundationModels 的 Transcript 展平成这里的中立结构，再交给各家 adapter 序列化。
//

import Foundation
import FoundationModels
import UIKit

// MARK: - 中立消息

struct ChatMessage: Sendable {
    enum Role: Sendable { case user, assistant }

    enum Part: Sendable {
        case text(String)
        /// 已编码好的图片数据 + MIME 类型
        case image(Data, mimeType: String)
    }

    var role: Role
    var parts: [Part]

    var textOnly: String {
        parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: "\n")
    }

    var hasImage: Bool {
        parts.contains { if case .image = $0 { return true } else { return false } }
    }
}

struct ChatPrompt: Sendable {
    var system: String?
    var messages: [ChatMessage]

    var containsImages: Bool { messages.contains(where: \.hasImage) }
}

/// 推理强度。刻意不直接用 ContextOptions.ReasoningLevel：
/// 那个类型是 iOS 27 才有的，绑上去会让整个 adapter 层连同它的测试一起
/// 被 @available 门槛挡在 iOS 26 之外。映射在 executor 边界上做一次即可。
enum ReasoningEffort: Sendable, Equatable {
    case light
    case moderate
    case deep
    case custom(String)
}

/// 从 GenerationOptions / ContextOptions 提炼出的、三家都能映射的调参
struct ChatTuning: Sendable {
    var temperature: Double?
    var maxTokens: Int?
    var reasoning: ReasoningEffort?
}

struct ChatCompletion: Sendable {
    var text: String
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
}

// MARK: - 错误

enum ThirdPartyModelError: LocalizedError {
    case notConfigured
    case invalidBaseURL
    case unauthorized
    case rateLimited(retryAfter: Date?)
    case httpError(status: Int, body: String)
    case emptyResponse
    case malformedResponse(String)
    case visionUnsupported
    case toolsUnsupported
    case timedOut(String)
    /// 服务端的内容安全策略拦下了这次请求
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String.loc("尚未配置第三方模型，请在设置中填写 API 地址、模型名和密钥")
        case .invalidBaseURL:
            return String.loc("API 地址无效，请检查是否以 http:// 或 https:// 开头")
        case .unauthorized:
            return String.loc("API 密钥无效或已过期")
        case .rateLimited(let retryAfter):
            if let retryAfter {
                let time = retryAfter.formatted(
                    Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale)
                )
                return String.loc("请求过于频繁，请在 \(time) 后重试")
            }
            return String.loc("请求过于频繁，请稍后重试")
        case .httpError(let status, let body):
            let detail = body.prefix(300)
            return String.loc("服务返回错误 \(status)：\(String(detail))")
        case .emptyResponse:
            return String.loc("模型没有返回任何内容")
        case .malformedResponse(let detail):
            return String.loc("无法解析模型返回的内容：\(detail)")
        case .visionUnsupported:
            return String.loc("当前第三方模型未开启图像支持，无法解析图片")
        case .toolsUnsupported:
            return String.loc("第三方模型通道暂不支持工具调用")
        case .timedOut:
            return String.loc("请求超时，可在设置中调长超时时间或换用更快的模型")
        case .blocked(let reason):
            return String.loc("内容被服务商的安全策略拦截：\(reason)")
        }
    }
}

// MARK: - Transcript 展平

enum TranscriptFlattener {

    /// 图片直传前先降采样：小票照片动辄 4000px，原图 base64 进请求体既慢又贵，
    /// 而金额/商户这类信息在 1536px 长边下已经足够清晰。
    private static let maxImageDimension: CGFloat = 1536
    private static let jpegQuality: CGFloat = 0.8

    @available(iOS 27.0, *)
    static func flatten(_ transcript: Transcript, allowsImages: Bool) throws -> ChatPrompt {
        var system: [String] = []
        var messages: [ChatMessage] = []

        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                let text = try render(instructions.segments, allowsImages: false).textOnly
                if !text.isEmpty { system.append(text) }

            case .prompt(let prompt):
                let parts = try render(prompt.segments, allowsImages: allowsImages).parts
                if !parts.isEmpty { messages.append(ChatMessage(role: .user, parts: parts)) }

            case .response(let response):
                let parts = try render(response.segments, allowsImages: false).parts
                if !parts.isEmpty { messages.append(ChatMessage(role: .assistant, parts: parts)) }

            case .toolCalls, .toolOutput:
                // 本 App 不给模型挂 Tool；真出现了说明调用方用错了通道，
                // 与其静默丢弃上下文，不如让 executor 早点报错（见 ThirdPartyExecutor）
                throw ThirdPartyModelError.toolsUnsupported

            case .reasoning:
                // 上一轮的推理过程不回传：各家的 reasoning 块格式互不兼容，
                // 而且本 App 都是单轮请求，没有跨轮复用推理的需求
                continue

            @unknown default:
                continue
            }
        }

        return ChatPrompt(
            system: system.isEmpty ? nil : system.joined(separator: "\n\n"),
            messages: messages
        )
    }

    @available(iOS 27.0, *)
    private static func render(
        _ segments: [Transcript.Segment],
        allowsImages: Bool
    ) throws -> ChatMessage {
        var parts: [ChatMessage.Part] = []

        for segment in segments {
            switch segment {
            case .text(let text) where !text.content.isEmpty:
                parts.append(.text(text.content))

            case .structure(let structured):
                parts.append(.text(structured.content.jsonString))

            case .attachment(let attachment):
                guard allowsImages else { throw ThirdPartyModelError.visionUnsupported }
                guard case .image(let image) = attachment.content else { continue }
                if let label = attachment.label, !label.isEmpty {
                    parts.append(.text(label))
                }
                let data = try encodeJPEG(image.cgImage)
                parts.append(.image(data, mimeType: "image/jpeg"))

            default:
                continue
            }
        }

        return ChatMessage(role: .user, parts: parts)
    }

    /// CGImage → 降采样后的 JPEG
    private static func encodeJPEG(_ cgImage: CGImage) throws -> Data {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = min(1, maxImageDimension / max(width, height))
        let target = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())

        let source = UIImage(cgImage: cgImage)
        let resized: UIImage = scale < 1
            ? UIGraphicsImageRenderer(size: target).image { _ in
                source.draw(in: CGRect(origin: .zero, size: target))
              }
            : source

        guard let data = resized.jpegData(compressionQuality: jpegQuality) else {
            throw ThirdPartyModelError.malformedResponse(String.loc("图片编码失败"))
        }
        return data
    }
}

// MARK: - 输出清洗

enum JSONResponseExtractor {

    /// 从模型回复里抠出那一段 JSON。
    /// 即便开了 json_schema，中转服务和弱模型仍然常见三种脏输出：
    /// ```json 围栏、JSON 前后带解释性文字、以及 <think> 推理块。
    /// FoundationModels 拿到 appendText 之后是按 schema 硬解析的，脏一点就整条失败，
    /// 所以在进框架之前先清一遍。
    static func extract(from raw: String) -> String {
        var text = raw

        // 去掉推理模型的思考块
        if let range = text.range(of: "</think>", options: .backwards) {
            text = String(text[range.upperBound...])
        }

        // 去掉 ``` 围栏
        if let fenced = fencedBlock(in: text) { text = fenced }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 抠出最外层的 {...} 或 [...]
        if let balanced = balancedJSON(in: trimmed) { return balanced }
        return trimmed
    }

    private static func fencedBlock(in text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        // 跳过 ``` 后面可能跟着的语言标注（json / JSON）
        var start = open.upperBound
        if let lineEnd = text[start...].firstIndex(of: "\n"),
           text[start..<lineEnd].trimmingCharacters(in: .whitespaces).count <= 8 {
            start = text.index(after: lineEnd)
        }
        guard let close = text.range(of: "```", range: start..<text.endIndex) else { return nil }
        return String(text[start..<close.lowerBound])
    }

    /// 扫描第一个 { 或 [，配对到对应的收尾符（跳过字符串字面量里的括号）
    private static func balancedJSON(in text: String) -> String? {
        guard let startIndex = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let opener = text[startIndex]
        let closer: Character = opener == "{" ? "}" : "]"

        var depth = 0
        var inString = false
        var escaped = false

        for index in text.indices[startIndex...] {
            let character = text[index]
            if escaped { escaped = false; continue }
            if inString {
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case opener: depth += 1
            case closer:
                depth -= 1
                if depth == 0 { return String(text[startIndex...index]) }
            default: break
            }
        }
        return nil
    }
}
