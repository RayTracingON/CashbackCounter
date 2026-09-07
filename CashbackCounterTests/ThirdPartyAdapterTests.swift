import XCTest
import FoundationModels
@testable import CashbackCounter

/// 三家 API 的请求体构造。
/// 这层没法靠模拟器验证（真跑要联网 + 真密钥 + iOS 27 运行时），
/// 但写错了不会崩、只会安静地拿不到结果，所以必须在这里钉死形状。
final class ThirdPartyAdapterTests: XCTestCase {

    // MARK: - Fixtures

    private func config(
        _ provider: ThirdPartyProvider,
        baseURL: String,
        vision: Bool = false,
        reasoning: Bool = false
    ) -> ThirdPartyModelConfig {
        var config = ThirdPartyModelConfig()
        config.provider = provider
        config.baseURL = baseURL
        config.modelName = "test-model"
        config.supportsVision = vision
        config.supportsReasoning = reasoning
        return config
    }

    private var textPrompt: ChatPrompt {
        ChatPrompt(
            system: "You are an expert receipt data extractor.",
            messages: [ChatMessage(role: .user, parts: [.text("7-ELEVEN 合計 500")])]
        )
    }

    private var imagePrompt: ChatPrompt {
        ChatPrompt(
            system: "Read the receipt.",
            messages: [ChatMessage(role: .user, parts: [
                .text("Analyze this."),
                .image(Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg")
            ])]
        )
    }

    private func receiptSchema() throws -> SchemaJSON {
        try SchemaJSON.from(CloudReceiptMetadata.generationSchema)
    }

    // MARK: - OpenAI 兼容

    func testOpenAIRequestShape() throws {
        let request = try OpenAICompatibleAdapter().makeRequest(
            prompt: textPrompt,
            schema: try receiptSchema(),
            schemaName: "CloudReceiptMetadata",
            tuning: ChatTuning(temperature: 0.2, maxTokens: 512, reasoning: nil),
            config: config(.openAICompatible, baseURL: "https://api.deepseek.com/v1"),
            apiKey: "sk-test",
            mode: .jsonSchema
        )

        XCTAssertEqual(request.url.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-test")

        XCTAssertEqual(request.body["model"]?.stringValue, "test-model")
        XCTAssertEqual(roles(in: request.body["messages"]), ["system", "user"])

        let format = request.body["response_format"]
        XCTAssertEqual(format?["type"]?.stringValue, "json_schema")
        XCTAssertEqual(format?["json_schema"]?["name"]?.stringValue, "CloudReceiptMetadata")
        XCTAssertEqual(format?["json_schema"]?["strict"].flatMap(bool), true)
        XCTAssertNotNil(format?["json_schema"]?["schema"]?["properties"])
    }

    /// 原生 json_schema 已经是硬约束，再把 schema 文本塞进 system 只是白烧 token
    func testOpenAISkipsSchemaTextWhenUsingNativeJSONSchema() throws {
        let request = try OpenAICompatibleAdapter().makeRequest(
            prompt: textPrompt, schema: try receiptSchema(), schemaName: "R",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: nil),
            config: config(.openAICompatible, baseURL: "https://api.openai.com/v1"),
            apiKey: "k", mode: .jsonSchema
        )
        XCTAssertFalse(systemText(of: request.body).contains("JSON Schema"))
    }

    /// 降级到 json_object 后没有硬约束了，schema 必须写进提示词
    func testOpenAIJSONObjectModeEmbedsSchemaInPrompt() throws {
        let request = try OpenAICompatibleAdapter().makeRequest(
            prompt: textPrompt, schema: try receiptSchema(), schemaName: "R",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: nil),
            config: config(.openAICompatible, baseURL: "https://api.openai.com/v1"),
            apiKey: "k", mode: .jsonObject
        )
        XCTAssertEqual(request.body["response_format"]?["type"]?.stringValue, "json_object")
        let system = systemText(of: request.body)
        XCTAssertTrue(system.contains("JSON Schema"))
        XCTAssertTrue(system.contains("\"merchant\""))
    }

    func testOpenAIPromptOnlyModeSendsNoResponseFormat() throws {
        let request = try OpenAICompatibleAdapter().makeRequest(
            prompt: textPrompt, schema: try receiptSchema(), schemaName: "R",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: nil),
            config: config(.openAICompatible, baseURL: "https://api.openai.com/v1"),
            apiKey: "k", mode: .promptOnly
        )
        XCTAssertNil(request.body["response_format"])
        XCTAssertTrue(systemText(of: request.body).contains("JSON Schema"))
    }

    /// 没勾「推理模式」就绝不能带 reasoning_effort：普通模型收到会直接 400
    func testOpenAIOmitsReasoningEffortUnlessEnabled() throws {
        let adapter = OpenAICompatibleAdapter()
        let tuning = ChatTuning(temperature: nil, maxTokens: nil, reasoning: .moderate)

        let off = try adapter.makeRequest(
            prompt: textPrompt, schema: nil, schemaName: "R", tuning: tuning,
            config: config(.openAICompatible, baseURL: "https://x.com/v1", reasoning: false),
            apiKey: "k", mode: .promptOnly
        )
        XCTAssertNil(off.body["reasoning_effort"])

        let on = try adapter.makeRequest(
            prompt: textPrompt, schema: nil, schemaName: "R", tuning: tuning,
            config: config(.openAICompatible, baseURL: "https://x.com/v1", reasoning: true),
            apiKey: "k", mode: .promptOnly
        )
        XCTAssertEqual(on.body["reasoning_effort"]?.stringValue, "medium")
    }

    /// 纯文本消息用字符串 content（很多兼容端点只实现了这一种）；带图才展开成数组
    func testOpenAIUsesStringContentForTextAndPartsForImages() throws {
        let adapter = OpenAICompatibleAdapter()
        let tuning = ChatTuning(temperature: nil, maxTokens: nil, reasoning: nil)

        let text = try adapter.makeRequest(
            prompt: textPrompt, schema: nil, schemaName: "R", tuning: tuning,
            config: config(.openAICompatible, baseURL: "https://x.com/v1"),
            apiKey: "k", mode: .promptOnly
        )
        XCTAssertNotNil(userMessage(in: text.body)?["content"]?.stringValue)

        let image = try adapter.makeRequest(
            prompt: imagePrompt, schema: nil, schemaName: "R", tuning: tuning,
            config: config(.openAICompatible, baseURL: "https://x.com/v1", vision: true),
            apiKey: "k", mode: .promptOnly
        )
        let parts = userMessage(in: image.body)?["content"]?.arrayValue
        XCTAssertEqual(parts?.count, 2)
        XCTAssertEqual(parts?.last?["type"]?.stringValue, "image_url")
        XCTAssertEqual(
            parts?.last?["image_url"]?["url"]?.stringValue,
            "data:image/jpeg;base64,\(Data([0xFF, 0xD8, 0xFF]).base64EncodedString())"
        )
    }

    // MARK: - Anthropic

    func testAnthropicRequestShape() throws {
        let request = try AnthropicAdapter().makeRequest(
            prompt: textPrompt,
            schema: try receiptSchema(),
            schemaName: "CloudReceiptMetadata",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: nil),
            config: config(.anthropic, baseURL: "https://api.anthropic.com"),
            apiKey: "sk-ant",
            mode: .jsonSchema
        )

        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.headers["x-api-key"], "sk-ant")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")

        // max_tokens 在 Anthropic 是必填项，没传也得有个默认值
        XCTAssertNotNil(request.body["max_tokens"])
        // system 是独立字段，不混进 messages
        XCTAssertEqual(request.body["system"]?.stringValue, textPrompt.system)
        XCTAssertEqual(roles(in: request.body["messages"]), ["user"])

        // 结构化输出走强制工具调用
        let tool = request.body["tools"]?.arrayValue?.first
        XCTAssertEqual(tool?["name"]?.stringValue, "emit_result")
        XCTAssertNotNil(tool?["input_schema"]?["properties"])
        XCTAssertEqual(request.body["tool_choice"]?["type"]?.stringValue, "tool")
        XCTAssertEqual(request.body["tool_choice"]?["name"]?.stringValue, "emit_result")
    }

    /// Anthropic 侧 extended thinking 和「强制某个工具」互斥，
    /// 同时带上去服务端会直接拒绝。
    func testAnthropicDoesNotEnableThinkingWhileForcingTool() throws {
        let request = try AnthropicAdapter().makeRequest(
            prompt: textPrompt, schema: try receiptSchema(), schemaName: "R",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: .deep),
            config: config(.anthropic, baseURL: "https://api.anthropic.com", reasoning: true),
            apiKey: "k", mode: .jsonSchema
        )
        XCTAssertNotNil(request.body["tool_choice"])
        XCTAssertNil(request.body["thinking"], "强制工具调用时不能同时开 thinking")
    }

    /// 不走工具的路径才能开推理，且 max_tokens 必须留出思考预算之外的空间
    func testAnthropicEnablesThinkingWithoutTool() throws {
        let request = try AnthropicAdapter().makeRequest(
            prompt: textPrompt, schema: nil, schemaName: "R",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: .moderate),
            config: config(.anthropic, baseURL: "https://api.anthropic.com", reasoning: true),
            apiKey: "k", mode: .promptOnly
        )
        XCTAssertEqual(request.body["thinking"]?["type"]?.stringValue, "enabled")

        let budget = request.body["thinking"]?["budget_tokens"].flatMap(number)
        let maxTokens = request.body["max_tokens"].flatMap(number)
        XCTAssertNotNil(budget)
        XCTAssertGreaterThan(maxTokens ?? 0, budget ?? 0)
    }

    func testAnthropicEncodesImageAsBase64Source() throws {
        let request = try AnthropicAdapter().makeRequest(
            prompt: imagePrompt, schema: nil, schemaName: "R",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: nil),
            config: config(.anthropic, baseURL: "https://api.anthropic.com", vision: true),
            apiKey: "k", mode: .promptOnly
        )
        let parts = userMessage(in: request.body)?["content"]?.arrayValue
        XCTAssertEqual(parts?.last?["type"]?.stringValue, "image")
        XCTAssertEqual(parts?.last?["source"]?["type"]?.stringValue, "base64")
        XCTAssertEqual(parts?.last?["source"]?["media_type"]?.stringValue, "image/jpeg")
    }

    // MARK: - Gemini

    func testGeminiRequestShape() throws {
        let request = try GeminiAdapter().makeRequest(
            prompt: textPrompt,
            schema: try receiptSchema(),
            schemaName: "CloudReceiptMetadata",
            tuning: ChatTuning(temperature: 0.1, maxTokens: 800, reasoning: nil),
            config: config(.gemini, baseURL: "https://generativelanguage.googleapis.com"),
            apiKey: "AIza-test",
            mode: .jsonSchema
        )

        XCTAssertEqual(
            request.url.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/test-model:generateContent"
        )
        // 密钥必须走请求头：URL 会进各级日志和崩溃报告
        XCTAssertEqual(request.headers["x-goog-api-key"], "AIza-test")
        XCTAssertFalse(request.url.absoluteString.contains("AIza-test"))

        XCTAssertNotNil(request.body["systemInstruction"]?["parts"])
        XCTAssertEqual(roles(in: request.body["contents"]), ["user"])

        let generation = request.body["generationConfig"]
        XCTAssertEqual(generation?["responseMimeType"]?.stringValue, "application/json")
        XCTAssertEqual(generation?["responseSchema"]?["type"]?.stringValue, "OBJECT")
        XCTAssertEqual(generation?["maxOutputTokens"].flatMap(number), 800)
    }

    func testGeminiMapsAssistantRoleToModel() throws {
        let prompt = ChatPrompt(system: nil, messages: [
            ChatMessage(role: .user, parts: [.text("hi")]),
            ChatMessage(role: .assistant, parts: [.text("{}")])
        ])
        let request = try GeminiAdapter().makeRequest(
            prompt: prompt, schema: nil, schemaName: "R",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: nil),
            config: config(.gemini, baseURL: "https://generativelanguage.googleapis.com"),
            apiKey: "k", mode: .promptOnly
        )
        XCTAssertEqual(roles(in: request.body["contents"]), ["user", "model"])
    }

    func testGeminiEncodesImageAsInlineData() throws {
        let request = try GeminiAdapter().makeRequest(
            prompt: imagePrompt, schema: nil, schemaName: "R",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: nil),
            config: config(.gemini, baseURL: "https://generativelanguage.googleapis.com", vision: true),
            apiKey: "k", mode: .promptOnly
        )
        let parts = request.body["contents"]?.arrayValue?.first?["parts"]?.arrayValue
        XCTAssertEqual(parts?.last?["inlineData"]?["mimeType"]?.stringValue, "image/jpeg")
        XCTAssertNotNil(parts?.last?["inlineData"]?["data"]?.stringValue)
    }

    // MARK: - 字段顺序端到端

    /// 顺序在 SchemaJSON 层已经测过，这里确认它一路穿过 adapter 活着到了请求体里
    func testPropertyOrderSurvivesIntoEveryProviderRequest() throws {
        let expected = ["merchant", "totalAmount", "currency", "dateString", "cardLast4", "category"]
        let schema = try receiptSchema()
        let tuning = ChatTuning(temperature: nil, maxTokens: nil, reasoning: nil)

        let openAI = try OpenAICompatibleAdapter().makeRequest(
            prompt: textPrompt, schema: schema, schemaName: "R", tuning: tuning,
            config: config(.openAICompatible, baseURL: "https://x.com/v1"), apiKey: "k", mode: .jsonSchema
        )
        XCTAssertEqual(
            openAI.body["response_format"]?["json_schema"]?["schema"]?["properties"]?
                .objectPairs?.map(\.key),
            expected
        )

        let anthropic = try AnthropicAdapter().makeRequest(
            prompt: textPrompt, schema: schema, schemaName: "R", tuning: tuning,
            config: config(.anthropic, baseURL: "https://api.anthropic.com"), apiKey: "k", mode: .jsonSchema
        )
        XCTAssertEqual(
            anthropic.body["tools"]?.arrayValue?.first?["input_schema"]?["properties"]?
                .objectPairs?.map(\.key),
            expected
        )

        let gemini = try GeminiAdapter().makeRequest(
            prompt: textPrompt, schema: schema, schemaName: "R", tuning: tuning,
            config: config(.gemini, baseURL: "https://g.com"), apiKey: "k", mode: .jsonSchema
        )
        let geminiSchema = gemini.body["generationConfig"]?["responseSchema"]
        XCTAssertEqual(geminiSchema?["properties"]?.objectPairs?.map(\.key), expected)
        XCTAssertEqual(
            geminiSchema?["propertyOrdering"]?.arrayValue?.compactMap { $0.stringValue },
            expected
        )
    }

    // MARK: - 响应解析

    func testOpenAIDecodesContentAndUsage() throws {
        let json: [String: Any] = [
            "choices": [["message": ["content": "{\"merchant\":\"Lawson\"}"]]],
            "usage": [
                "prompt_tokens": 120,
                "completion_tokens": 30,
                "prompt_tokens_details": ["cached_tokens": 64],
                "completion_tokens_details": ["reasoning_tokens": 12]
            ]
        ]
        let result = try OpenAICompatibleAdapter().decode(json, expectsSchema: true)
        XCTAssertEqual(result.text, "{\"merchant\":\"Lawson\"}")
        XCTAssertEqual(result.inputTokens, 120)
        XCTAssertEqual(result.cachedInputTokens, 64)
        XCTAssertEqual(result.outputTokens, 30)
        XCTAssertEqual(result.reasoningTokens, 12)
    }

    /// 走 tool 的中转层会把结构化结果放 tool_calls 而不是 content
    func testOpenAIFallsBackToToolCallArguments() throws {
        let json: [String: Any] = [
            "choices": [["message": [
                "content": "",
                "tool_calls": [["function": ["arguments": "{\"merchant\":\"FamilyMart\"}"]]]
            ]]]
        ]
        let result = try OpenAICompatibleAdapter().decode(json, expectsSchema: true)
        XCTAssertEqual(result.text, "{\"merchant\":\"FamilyMart\"}")
    }

    func testAnthropicDecodesForcedToolInput() throws {
        let json: [String: Any] = [
            "content": [
                ["type": "text", "text": "Here you go:"],
                ["type": "tool_use", "name": "emit_result", "input": ["merchant": "Lawson"]]
            ],
            "usage": ["input_tokens": 90, "output_tokens": 20, "cache_read_input_tokens": 40]
        ]
        let result = try AnthropicAdapter().decode(json, expectsSchema: true)
        XCTAssertTrue(result.text.contains("\"merchant\""))
        XCTAssertTrue(result.text.contains("Lawson"))
        XCTAssertFalse(result.text.contains("Here you go"), "工具入参优先于旁边的解释文字")
        XCTAssertEqual(result.inputTokens, 90)
        XCTAssertEqual(result.cachedInputTokens, 40)
    }

    /// thought:true 的 part 是推理过程，不能混进答案
    func testGeminiSkipsThoughtParts() throws {
        let json: [String: Any] = [
            "candidates": [["content": ["parts": [
                ["text": "let me think...", "thought": true],
                ["text": "{\"merchant\":\"Lawson\"}"]
            ]]]],
            "usageMetadata": ["promptTokenCount": 55, "candidatesTokenCount": 18, "thoughtsTokenCount": 200]
        ]
        let result = try GeminiAdapter().decode(json, expectsSchema: true)
        XCTAssertEqual(result.text, "{\"merchant\":\"Lawson\"}")
        XCTAssertEqual(result.reasoningTokens, 200)
    }

    func testGeminiSurfacesSafetyBlockAsBlockedError() {
        let json: [String: Any] = ["promptFeedback": ["blockReason": "SAFETY"]]
        XCTAssertThrowsError(try GeminiAdapter().decode(json, expectsSchema: true)) { error in
            guard case ThirdPartyModelError.blocked(let reason) = error else {
                return XCTFail("应识别为内容拦截，实际是 \(error)")
            }
            XCTAssertEqual(reason, "SAFETY")
        }
    }

    func testEmptyResponseIsRejected() {
        let json: [String: Any] = ["choices": [["message": ["content": "   "]]]]
        XCTAssertThrowsError(try OpenAICompatibleAdapter().decode(json, expectsSchema: true)) { error in
            guard case ThirdPartyModelError.emptyResponse = error else {
                return XCTFail("应识别为空响应，实际是 \(error)")
            }
        }
    }

    // MARK: - 地址校验

    func testInvalidBaseURLIsRejectedBeforeSending() {
        var broken = config(.openAICompatible, baseURL: "api.openai.com")
        broken.modelName = "m"
        XCTAssertThrowsError(try OpenAICompatibleAdapter().makeRequest(
            prompt: textPrompt, schema: nil, schemaName: "R",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: nil),
            config: broken, apiKey: "k", mode: .promptOnly
        ))
    }

    // MARK: - Helpers

    private func roles(in messages: SchemaJSON?) -> [String] {
        messages?.arrayValue?.compactMap { $0["role"]?.stringValue } ?? []
    }

    private func userMessage(in body: SchemaJSON) -> SchemaJSON? {
        let list = body["messages"] ?? body["contents"]
        return list?.arrayValue?.first { $0["role"]?.stringValue == "user" }
    }

    private func systemText(of body: SchemaJSON) -> String {
        if let system = body["system"]?.stringValue { return system }
        let message = body["messages"]?.arrayValue?.first { $0["role"]?.stringValue == "system" }
        return message?["content"]?.stringValue ?? ""
    }

    private func bool(_ json: SchemaJSON) -> Bool? {
        if case .bool(let value) = json { return value }
        return nil
    }

    private func number(_ json: SchemaJSON) -> Double? {
        if case .number(let value) = json { return value }
        return nil
    }
}
