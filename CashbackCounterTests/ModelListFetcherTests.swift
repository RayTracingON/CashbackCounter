import XCTest
@testable import CashbackCounter

/// 「从服务获取模型列表」的请求形状和响应解析。
/// 三家的列表接口路径、鉴权头、返回结构都不一样，写错了只会表现为「列表是空的」，
/// 所以和聊天请求一样在这里钉死。
final class ModelListFetcherTests: XCTestCase {

    private func config(_ format: ThirdPartyAPIFormat, baseURL: String) -> ThirdPartyModelConfig {
        var config = ThirdPartyModelConfig()
        config.apiFormat = format
        config.baseURL = baseURL
        return config
    }

    // MARK: - 请求

    func testOpenAICompatibleRequest() throws {
        let request = try ModelListFetcher.makeRequest(
            config: config(.openAICompatible, baseURL: "https://openrouter.ai/api/v1/"),
            apiKey: " sk-test "
        )
        XCTAssertEqual(request.url.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-test")
    }

    /// Ollama / LM Studio 不需要密钥：空密钥不能发一个 "Bearer " 出去
    func testOpenAICompatibleRequestWithoutKeyHasNoAuthHeader() throws {
        let request = try ModelListFetcher.makeRequest(
            config: config(.openAICompatible, baseURL: "http://localhost:11434/v1"),
            apiKey: ""
        )
        XCTAssertEqual(request.url.absoluteString, "http://localhost:11434/v1/models")
        XCTAssertNil(request.headers["Authorization"])
    }

    func testAnthropicRequest() throws {
        let request = try ModelListFetcher.makeRequest(
            config: config(.anthropic, baseURL: "https://relay.example.com"),
            apiKey: "k"
        )
        XCTAssertEqual(request.url.absoluteString, "https://relay.example.com/v1/models?limit=1000")
        XCTAssertEqual(request.headers["x-api-key"], "k")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
    }

    /// 密钥走请求头，不能出现在 URL 里（URL 会进日志）
    func testGeminiRequestKeepsKeyOutOfURL() throws {
        let request = try ModelListFetcher.makeRequest(
            config: config(.gemini, baseURL: "https://generativelanguage.googleapis.com"),
            apiKey: "g-key"
        )
        XCTAssertEqual(
            request.url.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"
        )
        XCTAssertEqual(request.headers["x-goog-api-key"], "g-key")
        XCTAssertFalse(request.url.absoluteString.contains("g-key"))
    }

    func testInvalidBaseURLThrows() {
        XCTAssertThrowsError(try ModelListFetcher.makeRequest(
            config: config(.openAICompatible, baseURL: "not a url"),
            apiKey: "k"
        ))
    }

    // MARK: - 解析

    func testDecodesOpenAIListSortedAndFiltered() {
        let json: [String: Any] = ["data": [
            ["id": "gpt-6-luna"],
            ["id": "text-embedding-3-large"],
            ["id": "whisper-1"],
            ["id": "gpt-6.1-sol"],
            ["id": "tts-1-hd"],
            ["id": "gpt-6-luna"]
        ]]
        let ids = ModelListFetcher.decode(json, format: .openAICompatible).map(\.id)
        XCTAssertEqual(ids, ["gpt-6-luna", "gpt-6.1-sol"], "去掉嵌入/语音模型、去重并按名字排序")
    }

    /// OpenRouter 在 architecture.input_modalities 里给了是否能看图，拿来预设图像识别开关
    func testDecodesOpenRouterVisionHint() {
        let json: [String: Any] = ["data": [
            ["id": "qwen/qwen3-vl-plus", "name": "Qwen: Qwen3 VL Plus",
             "architecture": ["input_modalities": ["text", "image"]]],
            ["id": "deepseek/deepseek-v4-pro", "name": "deepseek/deepseek-v4-pro",
             "architecture": ["input_modalities": ["text"]]],
            ["id": "plain-model"]
        ]]
        let models = Dictionary(uniqueKeysWithValues:
            ModelListFetcher.decode(json, format: .openAICompatible).map { ($0.id, $0) })

        XCTAssertEqual(models["qwen/qwen3-vl-plus"]?.supportsVision, true)
        XCTAssertEqual(models["qwen/qwen3-vl-plus"]?.displayName, "Qwen: Qwen3 VL Plus")
        XCTAssertEqual(models["deepseek/deepseek-v4-pro"]?.supportsVision, false)
        XCTAssertNil(models["deepseek/deepseek-v4-pro"]?.displayName, "和 id 一样的展示名不重复显示")
        XCTAssertNil(models["plain-model"]?.supportsVision, "没说就是不知道，不能当成不支持")
    }

    func testDecodesAnthropicList() {
        let json: [String: Any] = ["data": [
            ["id": "claude-sonnet-5-5", "display_name": "Claude Sonnet 5.5", "type": "model"],
            ["id": "claude-haiku-4-5", "display_name": "Claude Haiku 4.5", "type": "model"]
        ], "has_more": false]
        let models = ModelListFetcher.decode(json, format: .anthropic)
        XCTAssertEqual(models.map(\.id), ["claude-haiku-4-5", "claude-sonnet-5-5"])
        XCTAssertEqual(models.first?.displayName, "Claude Haiku 4.5")
    }

    /// Gemini 返回 "models/xxx"，而聊天请求路径会自己补 models/，必须剥掉；
    /// 嵌入模型不支持 generateContent，列出来也用不了
    func testDecodesGeminiListStripsPrefixAndDropsEmbeddings() {
        let json: [String: Any] = ["models": [
            ["name": "models/gemini-3.8-flash", "displayName": "Gemini 3.8 Flash",
             "supportedGenerationMethods": ["generateContent", "countTokens"]],
            ["name": "models/text-embedding-005",
             "supportedGenerationMethods": ["embedContent"]],
            ["name": "models/gemini-3.5-flash-lite",
             "supportedGenerationMethods": ["generateContent"]]
        ]]
        let models = ModelListFetcher.decode(json, format: .gemini)
        XCTAssertEqual(models.map(\.id), ["gemini-3.5-flash-lite", "gemini-3.8-flash"])
        XCTAssertEqual(models.last?.displayName, "Gemini 3.8 Flash")
    }

    func testUnexpectedShapeDecodesToEmpty() {
        XCTAssertTrue(ModelListFetcher.decode(["object": "list"], format: .openAICompatible).isEmpty)
        XCTAssertTrue(ModelListFetcher.decode(["error": "x"], format: .gemini).isEmpty)
    }
}
