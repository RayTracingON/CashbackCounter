//
//  ThirdPartyChatAdapters.swift
//  CashbackCounter
//
//  三家线上协议的序列化/反序列化。上层只认 ChatPrompt / ChatCompletion。
//
//  ⚠️ 请求体一律用 SchemaJSON 拼而不是 JSONSerialization：
//  schema 里的 properties 顺序是有语义的（见 SchemaJSON.swift 顶部），
//  一旦过一遍无序字典就全乱了。
//

import Foundation
import FoundationModels

// MARK: - 便捷构造

private func obj(_ pairs: [(String, SchemaJSON)]) -> SchemaJSON {
    .object(pairs.map { (key: $0.0, value: $0.1) })
}

private extension SchemaJSON {
    static func str(_ value: String) -> SchemaJSON { .string(value) }
    static func num(_ value: Double) -> SchemaJSON { .number(value) }
    static func num(_ value: Int) -> SchemaJSON { .number(Double(value)) }
}

// MARK: - Adapter 协议

/// 一次已经拼好、但还没发出去的 HTTP 请求。
/// 把「拼请求」和「发请求」分开，是为了能在不联网的情况下单测请求体
/// —— 三家的 body 形状差异大，写错了不会崩，只会安静地拿不到结果。
struct ChatHTTPRequest: Sendable {
    var url: URL
    var headers: [String: String]
    var body: SchemaJSON
}

protocol ThirdPartyChatAdapter: Sendable {
    func makeRequest(
        prompt: ChatPrompt,
        schema: SchemaJSON?,
        schemaName: String,
        tuning: ChatTuning,
        config: ThirdPartyModelConfig,
        apiKey: String,
        mode: StructuredOutputMode
    ) throws -> ChatHTTPRequest

    func decode(_ json: [String: Any], expectsSchema: Bool) throws -> ChatCompletion
}

extension ThirdPartyChatAdapter {
    func complete(
        prompt: ChatPrompt,
        schema: SchemaJSON?,
        schemaName: String,
        tuning: ChatTuning,
        config: ThirdPartyModelConfig,
        apiKey: String,
        mode: StructuredOutputMode
    ) async throws -> ChatCompletion {
        let request = try makeRequest(
            prompt: prompt, schema: schema, schemaName: schemaName,
            tuning: tuning, config: config, apiKey: apiKey, mode: mode
        )
        let json = try await ThirdPartyHTTP.post(
            url: request.url,
            headers: request.headers,
            body: request.body,
            timeout: config.timeout
        )
        return try decode(json, expectsSchema: schema != nil && mode == .jsonSchema)
    }
}

extension ThirdPartyProvider {
    var adapter: any ThirdPartyChatAdapter {
        switch self {
        case .openAICompatible: return OpenAICompatibleAdapter()
        case .anthropic:        return AnthropicAdapter()
        case .gemini:           return GeminiAdapter()
        }
    }
}

// MARK: - 共用工具

enum ThirdPartyHTTP {

    static func post(
        url: URL,
        headers: [String: String],
        body: SchemaJSON,
        timeout: Double
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = body.jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ThirdPartyModelError.timedOut(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ThirdPartyModelError.malformedResponse(String.loc("无效的 HTTP 响应"))
        }

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            switch http.statusCode {
            case 401, 403:
                throw ThirdPartyModelError.unauthorized
            case 429:
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init)).map { Date().addingTimeInterval($0) }
                throw ThirdPartyModelError.rateLimited(retryAfter: retryAfter)
            default:
                throw ThirdPartyModelError.httpError(status: http.statusCode, body: text)
            }
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ThirdPartyModelError.malformedResponse(String.loc("响应不是 JSON 对象"))
        }
        return json
    }

    /// 把 schema 以文本形式写进系统提示。json_object / promptOnly 两档靠它约束格式。
    static func systemPrompt(_ base: String?, schema: SchemaJSON?, describeSchema: Bool) -> String? {
        guard describeSchema, let schema else { return base }
        let instruction = """
        Respond with a single JSON object that conforms exactly to this JSON Schema. \
        Output raw JSON only: no markdown fences, no commentary, no trailing text. \
        Use null for any field you cannot determine. Keep the property order shown below.

        \(schema.serialized())
        """
        return [base, instruction].compactMap { $0 }.joined(separator: "\n\n")
    }
}

// MARK: - OpenAI 兼容

struct OpenAICompatibleAdapter: ThirdPartyChatAdapter {

    func makeRequest(
        prompt: ChatPrompt,
        schema: SchemaJSON?,
        schemaName: String,
        tuning: ChatTuning,
        config: ThirdPartyModelConfig,
        apiKey: String,
        mode: StructuredOutputMode
    ) throws -> ChatHTTPRequest {
        guard let base = config.normalizedBaseURL else { throw ThirdPartyModelError.invalidBaseURL }

        var messages: [SchemaJSON] = []
        if let system = ThirdPartyHTTP.systemPrompt(
            prompt.system, schema: schema, describeSchema: mode != .jsonSchema
        ) {
            messages.append(obj([("role", .str("system")), ("content", .str(system))]))
        }
        messages.append(contentsOf: prompt.messages.map(Self.encode))

        var body: [(String, SchemaJSON)] = [
            ("model", .str(config.modelName.trimmed)),
            ("messages", .array(messages))
        ]
        if let temperature = tuning.temperature { body.append(("temperature", .num(temperature))) }
        if let maxTokens = tuning.maxTokens { body.append(("max_tokens", .num(maxTokens))) }

        if let schema, mode == .jsonSchema {
            body.append(("response_format", obj([
                ("type", .str("json_schema")),
                ("json_schema", obj([
                    ("name", .str(schemaName)),
                    ("strict", .bool(true)),
                    ("schema", schema.openAIStrictSchema())
                ]))
            ])))
        } else if schema != nil, mode == .jsonObject {
            body.append(("response_format", obj([("type", .str("json_object"))])))
        }

        if config.supportsReasoning, let level = tuning.reasoning {
            body.append(("reasoning_effort", .str(Self.effort(for: level))))
        }

        return ChatHTTPRequest(
            url: base.appending(path: "chat/completions"),
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: obj(body)
        )
    }

    /// 单纯文本的 content 用字符串；带图才展开成 parts 数组
    /// （不少兼容端点只实现了字符串形态，能省则省）
    private static func encode(_ message: ChatMessage) -> SchemaJSON {
        let role = message.role == .user ? "user" : "assistant"
        guard message.hasImage else {
            return obj([("role", .str(role)), ("content", .str(message.textOnly))])
        }
        let parts: [SchemaJSON] = message.parts.map { part in
            switch part {
            case .text(let text):
                return obj([("type", .str("text")), ("text", .str(text))])
            case .image(let data, let mimeType):
                return obj([
                    ("type", .str("image_url")),
                    ("image_url", obj([
                        ("url", .str("data:\(mimeType);base64,\(data.base64EncodedString())"))
                    ]))
                ])
            }
        }
        return obj([("role", .str(role)), ("content", .array(parts))])
    }

    private static func effort(for level: ReasoningEffort) -> String {
        switch level {
        case .light:            return "low"
        case .moderate:         return "medium"
        case .deep:             return "high"
        case .custom(let raw):  return raw
        @unknown default:       return "medium"
        }
    }

    func decode(_ json: [String: Any], expectsSchema: Bool) throws -> ChatCompletion {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw ThirdPartyModelError.malformedResponse(String.loc("缺少 choices[0].message"))
        }
        // 有的服务把结构化结果放 content，有的（走 tool 的中转层）放 tool_calls
        var text = message["content"] as? String ?? ""
        if text.isEmpty,
           let calls = message["tool_calls"] as? [[String: Any]],
           let function = calls.first?["function"] as? [String: Any],
           let arguments = function["arguments"] as? String {
            text = arguments
        }
        guard !text.trimmed.isEmpty else { throw ThirdPartyModelError.emptyResponse }

        var completion = ChatCompletion(text: text)
        if let usage = json["usage"] as? [String: Any] {
            completion.inputTokens = usage["prompt_tokens"] as? Int ?? 0
            completion.outputTokens = usage["completion_tokens"] as? Int ?? 0
            completion.cachedInputTokens =
                (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            completion.reasoningTokens =
                (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0
        }
        return completion
    }
}

// MARK: - Anthropic

struct AnthropicAdapter: ThirdPartyChatAdapter {

    /// Anthropic 的 max_tokens 是必填项，没有「不限」这个取值
    private static let defaultMaxTokens = 4096
    private static let structuredToolName = "emit_result"

    func makeRequest(
        prompt: ChatPrompt,
        schema: SchemaJSON?,
        schemaName: String,
        tuning: ChatTuning,
        config: ThirdPartyModelConfig,
        apiKey: String,
        mode: StructuredOutputMode
    ) throws -> ChatHTTPRequest {
        guard let base = config.normalizedBaseURL else { throw ThirdPartyModelError.invalidBaseURL }

        // 强制工具调用是 Anthropic 上最稳的结构化输出方式；降级档位才退回提示词约束
        let usesTool = schema != nil && mode == .jsonSchema

        var body: [(String, SchemaJSON)] = [
            ("model", .str(config.modelName.trimmed)),
            ("max_tokens", .num(tuning.maxTokens ?? Self.defaultMaxTokens)),
            ("messages", .array(prompt.messages.map(Self.encode)))
        ]
        if let system = ThirdPartyHTTP.systemPrompt(
            prompt.system, schema: schema, describeSchema: !usesTool
        ) {
            body.append(("system", .str(system)))
        }
        if let temperature = tuning.temperature { body.append(("temperature", .num(temperature))) }

        if usesTool, let schema {
            body.append(("tools", .array([obj([
                ("name", .str(Self.structuredToolName)),
                ("description", .str("Return the extracted \(schemaName) fields.")),
                ("input_schema", schema.standardJSONSchema())
            ])])))
            body.append(("tool_choice", obj([
                ("type", .str("tool")), ("name", .str(Self.structuredToolName))
            ])))
        }

        // ⚠️ extended thinking 与「强制某个工具」在 Anthropic 侧互斥（tool_choice 必须是 auto/none），
        // 所以走工具的结构化路径不开推理；纯文本路径才开。
        if config.supportsReasoning, !usesTool, let level = tuning.reasoning {
            let budget = Self.thinkingBudget(for: level)
            let maxTokens = max(tuning.maxTokens ?? Self.defaultMaxTokens, budget + 1024)
            body = body.map { $0.0 == "max_tokens" ? ("max_tokens", .num(maxTokens)) : $0 }
            body.append(("thinking", obj([
                ("type", .str("enabled")), ("budget_tokens", .num(budget))
            ])))
        }

        return ChatHTTPRequest(
            url: base.appending(path: "v1/messages"),
            headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"],
            body: obj(body)
        )
    }

    private static func encode(_ message: ChatMessage) -> SchemaJSON {
        let role = message.role == .user ? "user" : "assistant"
        let parts: [SchemaJSON] = message.parts.map { part in
            switch part {
            case .text(let text):
                return obj([("type", .str("text")), ("text", .str(text))])
            case .image(let data, let mimeType):
                return obj([
                    ("type", .str("image")),
                    ("source", obj([
                        ("type", .str("base64")),
                        ("media_type", .str(mimeType)),
                        ("data", .str(data.base64EncodedString()))
                    ]))
                ])
            }
        }
        return obj([("role", .str(role)), ("content", .array(parts))])
    }

    private static func thinkingBudget(for level: ReasoningEffort) -> Int {
        switch level {
        case .light:      return 1024
        case .moderate:   return 4096
        case .deep:       return 12288
        case .custom(let raw): return Int(raw) ?? 4096
        @unknown default: return 4096
        }
    }

    func decode(_ json: [String: Any], expectsSchema expectingTool: Bool) throws -> ChatCompletion {
        guard let blocks = json["content"] as? [[String: Any]] else {
            throw ThirdPartyModelError.malformedResponse(String.loc("缺少 content"))
        }

        var text = ""
        if expectingTool,
           let toolUse = blocks.first(where: { $0["type"] as? String == "tool_use" }),
           let input = toolUse["input"] {
            // 工具入参已经是解析好的 JSON，重新序列化成文本交回框架按 schema 解析
            text = (try? JSONSerialization.data(withJSONObject: input))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        if text.isEmpty {
            text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
        }
        guard !text.trimmed.isEmpty else { throw ThirdPartyModelError.emptyResponse }

        var completion = ChatCompletion(text: text)
        if let usage = json["usage"] as? [String: Any] {
            completion.inputTokens = usage["input_tokens"] as? Int ?? 0
            completion.outputTokens = usage["output_tokens"] as? Int ?? 0
            completion.cachedInputTokens = usage["cache_read_input_tokens"] as? Int ?? 0
        }
        return completion
    }
}

// MARK: - Google Gemini

struct GeminiAdapter: ThirdPartyChatAdapter {

    func makeRequest(
        prompt: ChatPrompt,
        schema: SchemaJSON?,
        schemaName: String,
        tuning: ChatTuning,
        config: ThirdPartyModelConfig,
        apiKey: String,
        mode: StructuredOutputMode
    ) throws -> ChatHTTPRequest {
        guard let base = config.normalizedBaseURL else { throw ThirdPartyModelError.invalidBaseURL }

        var generationConfig: [(String, SchemaJSON)] = []
        if let temperature = tuning.temperature { generationConfig.append(("temperature", .num(temperature))) }
        if let maxTokens = tuning.maxTokens { generationConfig.append(("maxOutputTokens", .num(maxTokens))) }

        if let schema, mode != .promptOnly {
            generationConfig.append(("responseMimeType", .str("application/json")))
            if mode == .jsonSchema {
                generationConfig.append(("responseSchema", schema.geminiSchema()))
            }
        }
        if config.supportsReasoning, let level = tuning.reasoning {
            generationConfig.append(("thinkingConfig", obj([
                ("thinkingBudget", .num(Self.thinkingBudget(for: level)))
            ])))
        }

        var body: [(String, SchemaJSON)] = [
            ("contents", .array(prompt.messages.map(Self.encode)))
        ]
        if let system = ThirdPartyHTTP.systemPrompt(
            prompt.system, schema: schema, describeSchema: mode != .jsonSchema
        ) {
            body.append(("systemInstruction", obj([
                ("parts", .array([obj([("text", .str(system))])]))
            ])))
        }
        if !generationConfig.isEmpty {
            body.append(("generationConfig", obj(generationConfig)))
        }

        // 密钥走请求头而不是 ?key= 查询参数：URL 会进各级日志和崩溃报告
        let model = config.modelName.trimmed
        return ChatHTTPRequest(
            url: base.appending(path: "v1beta/models/\(model):generateContent"),
            headers: ["x-goog-api-key": apiKey],
            body: obj(body)
        )
    }

    private static func encode(_ message: ChatMessage) -> SchemaJSON {
        let role = message.role == .user ? "user" : "model"
        let parts: [SchemaJSON] = message.parts.map { part in
            switch part {
            case .text(let text):
                return obj([("text", .str(text))])
            case .image(let data, let mimeType):
                return obj([("inlineData", obj([
                    ("mimeType", .str(mimeType)),
                    ("data", .str(data.base64EncodedString()))
                ]))])
            }
        }
        return obj([("role", .str(role)), ("parts", .array(parts))])
    }

    private static func thinkingBudget(for level: ReasoningEffort) -> Int {
        switch level {
        case .light:      return 512
        case .moderate:   return 4096
        case .deep:       return 12288
        case .custom(let raw): return Int(raw) ?? 4096
        @unknown default: return 4096
        }
    }

    func decode(_ json: [String: Any], expectsSchema: Bool) throws -> ChatCompletion {
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            // 触发安全过滤时没有 candidates，只有 promptFeedback
            if let feedback = json["promptFeedback"] as? [String: Any],
               let reason = feedback["blockReason"] as? String {
                throw ThirdPartyModelError.blocked(reason)
            }
            throw ThirdPartyModelError.malformedResponse(String.loc("缺少 candidates[0].content"))
        }

        // thought:true 的 part 是推理过程，不是答案
        let text = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.trimmed.isEmpty else { throw ThirdPartyModelError.emptyResponse }

        var completion = ChatCompletion(text: text)
        if let usage = json["usageMetadata"] as? [String: Any] {
            completion.inputTokens = usage["promptTokenCount"] as? Int ?? 0
            completion.outputTokens = usage["candidatesTokenCount"] as? Int ?? 0
            completion.cachedInputTokens = usage["cachedContentTokenCount"] as? Int ?? 0
            completion.reasoningTokens = usage["thoughtsTokenCount"] as? Int ?? 0
        }
        return completion
    }
}
