import XCTest
import FoundationModels
import ClaudeForFoundationModels
@testable import CashbackCounter

/// 服务商（内置预设 + 自定义）这一层的纯逻辑：
/// 老配置能否读回、DeepSeek 的思考开关、旧版单一配置迁移、Claude 型号对得上官方包。
/// 这些坏了都不会崩，只会让用户的配置凭空消失或每张小票都慢吞吞地跑推理。
final class ModelProviderTests: XCTestCase {

    // MARK: - 配置向后兼容

    /// 旧版本存下的 JSON：协议字段叫 provider，也没有 thinkingSwitch。
    /// 合成的 Codable 遇到缺键会抛错，一抛错用户填过的配置就全丢了
    func testLegacyConfigJSONStillDecodes() throws {
        let json = """
        {"provider":"anthropic","baseURL":"https://relay.example.com","modelName":"m",
         "supportsVision":true,"supportsReasoning":false,"structuredOutputMode":"jsonObject","timeout":45}
        """
        let config = try JSONDecoder().decode(ThirdPartyModelConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.apiFormat, .anthropic)
        XCTAssertEqual(config.baseURL, "https://relay.example.com")
        XCTAssertEqual(config.modelName, "m")
        XCTAssertTrue(config.supportsVision)
        XCTAssertEqual(config.structuredOutputMode, .jsonObject)
        XCTAssertEqual(config.timeout, 45)
        XCTAssertEqual(config.thinkingSwitch, .none, "缺失的新字段应取默认值")
    }

    /// 协议字段在 Swift 里改名叫 apiFormat，但落盘的键名必须还是 provider
    func testConfigKeepsLegacyKeyNameWhenEncoding() throws {
        var config = ThirdPartyModelConfig()
        config.apiFormat = .gemini
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        XCTAssertEqual(object?["provider"] as? String, "gemini")
        XCTAssertNil(object?["apiFormat"])
    }

    func testProviderRoundTrips() throws {
        var provider = ModelProvider.newCustom()
        provider.customName = "公司中转"
        provider.config.baseURL = "https://relay.example.com/v1"
        provider.config.modelName = "qwen-max"
        let decoded = try JSONDecoder().decode(ModelProvider.self, from: JSONEncoder().encode(provider))
        XCTAssertEqual(decoded, provider)
    }

    // MARK: - DeepSeek

    func testDeepSeekPresetDefaults() {
        let config = ModelProviderPreset.deepSeek.defaultConfig
        XCTAssertEqual(config.apiFormat, .openAICompatible)
        XCTAssertEqual(config.normalizedBaseURL?.absoluteString, "https://api.deepseek.com")
        XCTAssertEqual(config.modelName, "deepseek-flash")
        XCTAssertTrue(config.supportsVision, "deepseek-flash 支持图片")
        XCTAssertFalse(config.supportsReasoning, "推理默认关，小票要的是快")
        XCTAssertEqual(config.structuredOutputMode, .jsonObject, "DeepSeek 只认 json_object")
        XCTAssertEqual(config.thinkingSwitch, .thinkingType)
    }

    /// DeepSeek 默认开思考：不想推理时光不发 reasoning_effort 不够，必须显式关
    func testDeepSeekRequestDisablesThinkingByDefault() throws {
        let request = try deepSeekRequest(reasoningEnabled: false, requested: .moderate)
        XCTAssertEqual(request.body["thinking"]?["type"]?.stringValue, "disabled")
        XCTAssertNil(request.body["reasoning_effort"])
        XCTAssertEqual(request.url.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.body["response_format"]?["type"]?.stringValue, "json_object")
    }

    func testDeepSeekRequestEnablesThinkingWhenReasoningRequested() throws {
        let request = try deepSeekRequest(reasoningEnabled: true, requested: .moderate)
        XCTAssertEqual(request.body["thinking"]?["type"]?.stringValue, "enabled")
        XCTAssertEqual(request.body["reasoning_effort"]?.stringValue, "medium")
    }

    /// 开了推理模式但这个场景不要推理（ReceiptParser 只给部分场景设档位）→ 照样要关
    func testDeepSeekDisablesThinkingWhenSceneHasNoReasoningLevel() throws {
        let request = try deepSeekRequest(reasoningEnabled: true, requested: nil)
        XCTAssertEqual(request.body["thinking"]?["type"]?.stringValue, "disabled")
        XCTAssertNil(request.body["reasoning_effort"])
    }

    /// 标准 OpenAI 不认 thinking 字段，绝不能带上
    func testStandardOpenAINeverSendsThinkingField() throws {
        let config = ModelProviderPreset.openAI.defaultConfig
        let request = try OpenAICompatibleAdapter().makeRequest(
            prompt: prompt, schema: nil, schemaName: "R",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: .light),
            config: config, apiKey: "k", mode: .promptOnly
        )
        XCTAssertNil(request.body["thinking"])
    }

    // MARK: - Claude

    /// 官方包只认编译进去的型号（靠能力表决定发哪些字段），预设里列的必须都能对上
    func testEveryClaudeOptionIsKnownToOfficialPackage() {
        for option in ModelProviderPreset.claude.modelOptions {
            let model = ClaudeModelCatalog.model(id: option.id)
            XCTAssertNotNil(model, "\(option.id) 不在 ClaudeForFoundationModels 的型号表里")
            XCTAssertEqual(model?.capabilities.imageInput, option.supportsVision, option.id)
        }
    }

    func testClaudeProviderWithUnknownModelIsIncomplete() {
        var provider = ModelProvider.builtIn(.claude)
        XCTAssertTrue(provider.isComplete)
        provider.config.modelName = "claude-made-up-9"
        XCTAssertFalse(provider.isComplete, "认不出的 Claude 型号不能当作可用")
    }

    // MARK: - 内置服务商以预设为准

    func testNormalizedRestoresBuiltInEndpoint() {
        var provider = ModelProvider.builtIn(.deepSeek)
        provider.config.baseURL = "https://evil.example.com"
        provider.config.thinkingSwitch = .none
        provider.config.modelName = "deepseek-v4-pro"

        let normalized = provider.normalized()
        XCTAssertEqual(normalized.config.baseURL, ModelProviderPreset.deepSeek.baseURL)
        XCTAssertEqual(normalized.config.thinkingSwitch, .thinkingType)
        XCTAssertEqual(normalized.config.modelName, "deepseek-v4-pro", "用户选的模型不该被覆盖")
    }

    func testCustomProviderIsNotNormalized() {
        var provider = ModelProvider.newCustom()
        provider.config.baseURL = "https://relay.example.com/v1"
        XCTAssertEqual(provider.normalized(), provider)
    }

    // MARK: - 旧版单一配置迁移

    func testMigrationMapsDeepSeekEndpointToBuiltIn() {
        var legacy = ThirdPartyModelConfig()
        legacy.apiFormat = .openAICompatible
        legacy.baseURL = "https://api.deepseek.com/v1"
        legacy.modelName = "deepseek-v4-pro"
        legacy.supportsVision = false

        let provider = ModelProvider.migrated(from: legacy)
        XCTAssertEqual(provider.preset, .deepSeek)
        XCTAssertEqual(provider.id, "builtin.deepSeek")
        XCTAssertEqual(provider.config.modelName, "deepseek-v4-pro")
        XCTAssertFalse(provider.config.supportsVision)
        XCTAssertEqual(provider.config.thinkingSwitch, .thinkingType, "迁移后要带上 DeepSeek 的思考开关")
        XCTAssertEqual(provider.config.structuredOutputMode, .jsonObject, ".auto 的老配置用预设档位")
    }

    func testMigrationKeepsUnknownEndpointAsCustom() {
        var legacy = ThirdPartyModelConfig()
        legacy.baseURL = "https://api.siliconflow.cn/v1"
        legacy.modelName = "Qwen/Qwen3-VL"
        legacy.supportsVision = true

        let provider = ModelProvider.migrated(from: legacy)
        XCTAssertNil(provider.preset)
        XCTAssertEqual(provider.customName, "api.siliconflow.cn")
        XCTAssertEqual(provider.config, legacy, "自定义服务商应原样保留旧配置")
    }

    /// Anthropic 地址但型号不在官方包的表里：并进内置 Claude 会变成不可用，只能当自定义
    func testMigrationOfUnknownClaudeModelBecomesCustom() {
        var legacy = ThirdPartyModelConfig()
        legacy.apiFormat = .anthropic
        legacy.baseURL = "https://api.anthropic.com"
        legacy.modelName = "claude-sonnet-4-5"

        let provider = ModelProvider.migrated(from: legacy)
        XCTAssertNil(provider.preset)
        XCTAssertEqual(provider.config.apiFormat, .anthropic)
        XCTAssertTrue(provider.isComplete)
    }

    func testMigrationOfKnownClaudeModelBecomesBuiltIn() {
        var legacy = ThirdPartyModelConfig()
        legacy.apiFormat = .anthropic
        legacy.baseURL = "https://api.anthropic.com/"
        legacy.modelName = "claude-haiku-4-5"

        let provider = ModelProvider.migrated(from: legacy)
        XCTAssertEqual(provider.preset, .claude)
        XCTAssertEqual(provider.config.modelName, "claude-haiku-4-5")
    }

    // MARK: - Helpers

    private var prompt: ChatPrompt {
        ChatPrompt(system: "Extract.", messages: [ChatMessage(role: .user, parts: [.text("合計 500")])])
    }

    private func deepSeekRequest(reasoningEnabled: Bool, requested: ReasoningEffort?) throws -> ChatHTTPRequest {
        var config = ModelProviderPreset.deepSeek.defaultConfig
        config.supportsReasoning = reasoningEnabled
        return try OpenAICompatibleAdapter().makeRequest(
            prompt: prompt,
            schema: try SchemaJSON.from(CloudReceiptMetadata.generationSchema),
            schemaName: "CloudReceiptMetadata",
            tuning: ChatTuning(temperature: nil, maxTokens: nil, reasoning: requested),
            config: config,
            apiKey: "sk-test",
            mode: config.structuredOutputMode
        )
    }
}
