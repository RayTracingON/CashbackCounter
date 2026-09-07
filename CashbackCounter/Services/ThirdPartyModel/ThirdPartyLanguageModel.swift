//
//  ThirdPartyLanguageModel.swift
//  CashbackCounter
//
//  把用户自带的第三方 API 接成一个平级的 FoundationModels 模型。
//
//  这是整个功能的支点：iOS 27 的 LanguageModel / LanguageModelExecutor 协议
//  （WWDC26）就是 SystemLanguageModel 和 PrivateCloudComputeLanguageModel 自己用的那套。
//  实现它之后，第三方模型可以直接塞进现成的 LanguageModelSession(model:instructions:)
//  和 DynamicProfile 的 .model()，于是 ReceiptParser 里那一整套
//  @Generable schema、按场景分家的 prompt 配方、respond(generating:) 全部零改动复用。
//

import Foundation
import FoundationModels

// MARK: - 模型

@available(iOS 27.0, *)
struct ThirdPartyLanguageModel: LanguageModel {
    typealias Executor = ThirdPartyModelExecutor

    let config: ThirdPartyModelConfig
    let apiKey: String

    var capabilities: LanguageModelCapabilities {
        var list: [LanguageModelCapabilities.Capability] = [.guidedGeneration]
        if config.supportsVision { list.append(.vision) }
        if config.supportsReasoning { list.append(.reasoning) }
        // 刻意不声明 .toolCalling：本 App 从不给模型挂 Tool，
        // 声明一个没实现的能力只会让上层以为能用（executor 里也会显式拒绝）
        return LanguageModelCapabilities(list)
    }

    var executorConfiguration: ThirdPartyModelExecutor.Configuration {
        .init(config: config, apiKey: apiKey)
    }

    /// 按当前设置构造；未配置齐全（缺 endpoint / 模型名 / 密钥）时返回 nil，调用方回退别的通道
    static func current() -> ThirdPartyLanguageModel? {
        let config = ThirdPartyModelStore.config
        guard config.isComplete, let apiKey = ThirdPartyModelStore.apiKey, !apiKey.isEmpty else {
            return nil
        }
        return ThirdPartyLanguageModel(config: config, apiKey: apiKey)
    }
}

// MARK: - Executor

@available(iOS 27.0, *)
struct ThirdPartyModelExecutor: LanguageModelExecutor {
    typealias Model = ThirdPartyLanguageModel

    /// 框架按 Configuration 做 executor 的复用/去重，所以密钥也要参与相等性：
    /// 换了 key 必须换 executor。
    struct Configuration: Hashable, Sendable {
        let config: ThirdPartyModelConfig
        let apiKey: String
    }

    let configuration: Configuration

    init(configuration: Configuration) throws {
        guard configuration.config.isComplete, !configuration.apiKey.isEmpty else {
            throw ThirdPartyModelError.notConfigured
        }
        self.configuration = configuration
    }

    /// 远端模型没有本地权重可加载，预热是空操作
    func prewarm(model: Model, transcript: Transcript) {}

    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        guard request.enabledToolDefinitions.isEmpty else {
            throw LanguageModelError.unsupportedCapability(.init(
                capability: .toolCalling,
                debugDescription: "ThirdPartyLanguageModel does not implement tool calling."
            ))
        }

        let config = configuration.config
        let prompt = try TranscriptFlattener.flatten(
            request.transcript,
            allowsImages: config.supportsVision
        )

        // 结构化输出的 schema 有两个来源：request.schema，以及最后一条 prompt 自带的
        // responseFormat。系统 executor 走哪个是框架内部约定，这里两边都读，
        // 少一个都会让 respond(generating:) 退化成「发一段自由文本再硬解析」。
        let resolvedSchema = request.schema ?? Self.schemaFromResponseFormat(in: request.transcript)
        let schema = try resolvedSchema.map { try SchemaJSON.from($0) }
        let schemaName = resolvedSchema?.name ?? "Result"

        let tuning = ChatTuning(
            temperature: request.generationOptions.temperature,
            maxTokens: request.generationOptions.maximumResponseTokens,
            reasoning: Self.effort(for: request.contextOptions.reasoningLevel)
        )

        let completion: ChatCompletion
        do {
            completion = try await ThirdPartyChatClient.complete(
                prompt: prompt,
                schema: schema,
                schemaName: schemaName,
                tuning: tuning,
                config: config,
                apiKey: configuration.apiKey
            )
        } catch let error as ThirdPartyModelError {
            // 有对应框架错误的抬成框架错误，上层（含系统 UI）才能按类型处理；
            // 其余保留自己的中文文案原样抛出
            throw Self.elevated(error)
        }

        // 结构化请求时先把围栏/前后缀清掉再交给框架：
        // 框架拿到 appendText 之后是按 schema 硬解析的，脏一个字符整条就失败
        let text = schema == nil
            ? completion.text
            : JSONResponseExtractor.extract(from: completion.text)

        await channel.send(.response(action: .appendText(text, tokenCount: completion.outputTokens)))
        await channel.send(.response(action: .updateUsage(
            input: .init(
                totalTokenCount: completion.inputTokens,
                cachedTokenCount: completion.cachedInputTokens
            ),
            output: .init(
                totalTokenCount: completion.outputTokens,
                reasoningTokenCount: completion.reasoningTokens
            )
        )))
    }

    private static func schemaFromResponseFormat(in transcript: Transcript) -> GenerationSchema? {
        for entry in transcript.reversed() {
            guard case .prompt(let prompt) = entry,
                  let format = prompt.responseFormat else { continue }
            if case .schema(let schema) = format.kind { return schema }
        }
        return nil
    }

    /// ContextOptions.ReasoningLevel（iOS 27）→ adapter 层的框架无关表示
    private static func effort(for level: ContextOptions.ReasoningLevel?) -> ReasoningEffort? {
        switch level {
        case .none:                 return nil
        case .light:                return .light
        case .moderate:             return .moderate
        case .deep:                 return .deep
        case .custom(let raw):      return .custom(raw)
        @unknown default:           return .moderate
        }
    }

    private static func elevated(_ error: ThirdPartyModelError) -> any Error {
        switch error {
        case .timedOut(let detail):
            return LanguageModelError.timeout(.init(debugDescription: detail))
        case .rateLimited(let resetDate):
            return LanguageModelError.rateLimited(.init(
                resetDate: resetDate,
                debugDescription: error.localizedDescription
            ))
        case .blocked(let reason):
            return LanguageModelError.guardrailViolation(.init(debugDescription: reason))
        case .visionUnsupported:
            return LanguageModelError.unsupportedCapability(.init(
                capability: .vision,
                debugDescription: error.localizedDescription
            ))
        case .toolsUnsupported:
            return LanguageModelError.unsupportedCapability(.init(
                capability: .toolCalling,
                debugDescription: error.localizedDescription
            ))
        default:
            return error
        }
    }
}

// MARK: - 请求调度与自动降级

/// 负责「用哪一档结构化输出」以及失败时的逐级降级。
///
/// 为什么需要降级：自建和中转的 OpenAI 兼容端点五花八门，很多只认 json_object，
/// 甚至完全不认 response_format。一次探测的结果按 endpoint+模型缓存下来，
/// 之后不再重复付这个成本（换服务商或换模型自动失效）。
enum ThirdPartyChatClient {

    static func complete(
        prompt: ChatPrompt,
        schema: SchemaJSON?,
        schemaName: String,
        tuning: ChatTuning,
        config: ThirdPartyModelConfig,
        apiKey: String
    ) async throws -> ChatCompletion {
        let adapter = config.provider.adapter

        // 没有 schema 就无所谓降级，直接发
        guard schema != nil else {
            return try await adapter.complete(
                prompt: prompt, schema: nil, schemaName: schemaName,
                tuning: tuning, config: config, apiKey: apiKey, mode: .promptOnly
            )
        }

        // 用户显式指定了档位就不自动降级——他知道自己的服务是什么样
        guard config.structuredOutputMode == .auto else {
            return try await adapter.complete(
                prompt: prompt, schema: schema, schemaName: schemaName,
                tuning: tuning, config: config, apiKey: apiKey,
                mode: config.structuredOutputMode
            )
        }

        let ladder: [StructuredOutputMode] = [.jsonSchema, .jsonObject, .promptOnly]
        let start = ThirdPartyModelStore.cachedStructuredMode(for: config)
            .flatMap { ladder.firstIndex(of: $0) } ?? 0

        var lastError: Error?
        for mode in ladder[start...] {
            do {
                let result = try await adapter.complete(
                    prompt: prompt, schema: schema, schemaName: schemaName,
                    tuning: tuning, config: config, apiKey: apiKey, mode: mode
                )
                ThirdPartyModelStore.cacheStructuredMode(mode, for: config)
                return result
            } catch let error where isSchemaRejection(error) {
                print("⚠️ 第三方模型不接受 \(mode.rawValue) 结构化输出，降级重试")
                lastError = error
                continue
            }
        }
        throw lastError ?? ThirdPartyModelError.emptyResponse
    }

    /// 判断这次失败是不是「服务端不认这种结构化输出参数」。
    /// 只有这一类才值得降级重试；鉴权失败、限流、超时都应该直接抛给用户。
    private static func isSchemaRejection(_ error: Error) -> Bool {
        guard case ThirdPartyModelError.httpError(let status, let body) = error,
              status == 400 || status == 404 || status == 422 else { return false }
        let lowered = body.lowercased()
        let markers = [
            "response_format", "json_schema", "responseschema", "response_schema",
            "structured output", "tool_choice", "input_schema", "not supported",
            "unsupported", "unknown parameter", "invalid parameter", "unrecognized"
        ]
        return markers.contains { lowered.contains($0) }
    }
}
