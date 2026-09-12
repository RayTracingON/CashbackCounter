//
//  ThirdPartyModelConfig.swift
//  CashbackCounter
//
//  用户自带的第三方模型 API 配置（替代 Apple Private Cloud Compute 做云端解析）。
//
//  设计要点：
//  - 配置本体（endpoint / 模型名 / 能力开关）是普通偏好，放 UserDefaults。
//  - API Key 是「能花用户的钱」的凭据，和会话 token 同级，必须进 Keychain。
//    见 KeychainStore 顶部关于 UserDefaults 明文 plist 的说明。
//  - 配置结构体本身刻意保持 Hashable + Sendable：它要作为
//    LanguageModelExecutor.Configuration 的一部分被框架缓存/比较。
//

import Foundation

// MARK: - 协议格式

/// 第三方 API 的线上协议格式。三家的请求体、鉴权头、结构化输出机制都不同，
/// 各由一个 adapter 负责（见 ThirdPartyChatAdapter）。
nonisolated enum ThirdPartyProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    /// OpenAI Chat Completions 格式。事实标准，兼容 DeepSeek / Kimi / 通义千问兼容模式 /
    /// 智谱 / SiliconFlow / OpenRouter / Ollama / LM Studio / vLLM 等绝大多数服务。
    case openAICompatible
    /// Anthropic Messages 格式（/v1/messages，x-api-key 鉴权，结构化输出走强制工具调用）
    case anthropic
    /// Google Gemini generateContent 格式（responseSchema 走 OpenAPI 3.0 子集方言）
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return String.loc("OpenAI 兼容")
        case .anthropic:        return String.loc("Anthropic")
        case .gemini:           return String.loc("Google Gemini")
        }
    }

    /// 预填的 Base URL 示例。用户换服务商时只改这一项。
    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic:        return "https://api.anthropic.com"
        case .gemini:           return "https://generativelanguage.googleapis.com"
        }
    }

    var defaultModelName: String {
        switch self {
        case .openAICompatible: return "gpt-4.1-mini"
        case .anthropic:        return "claude-sonnet-4-5"
        case .gemini:           return "gemini-2.5-flash"
        }
    }

    /// 设置页里给用户的一句话说明
    var hint: String {
        switch self {
        case .openAICompatible:
            return String.loc("填到 /v1 为止，例如 https://api.deepseek.com/v1。兼容任何 OpenAI 格式的服务。")
        case .anthropic:
            return String.loc("填服务根地址，例如 https://api.anthropic.com，路径由 App 补全。")
        case .gemini:
            return String.loc("填服务根地址，例如 https://generativelanguage.googleapis.com。")
        }
    }
}

// MARK: - 结构化输出策略

/// 各家对「保证输出合法 JSON」的支持程度参差不齐，尤其是自建/中转的 OpenAI 兼容端点：
/// 很多只实现了 json_object，甚至完全不认 response_format。
/// .auto 会在首次请求时逐级降级并把结果记下来，避免每次都付探测成本。
nonisolated enum StructuredOutputMode: String, Codable, CaseIterable, Sendable {
    /// 自动探测并降级：json_schema → json_object → 纯 prompt 约束
    case auto
    /// 强制 json_schema（OpenAI strict / Gemini responseSchema / Anthropic 强制工具调用）
    case jsonSchema
    /// 只要求「输出 JSON」，schema 以文本形式写进 prompt
    case jsonObject
    /// 完全不用 API 侧约束，只靠 prompt 描述 schema
    case promptOnly

    var displayName: String {
        switch self {
        case .auto:       return String.loc("自动（推荐）")
        case .jsonSchema: return String.loc("JSON Schema")
        case .jsonObject: return String.loc("JSON 模式")
        case .promptOnly: return String.loc("仅提示词约束")
        }
    }
}

// MARK: - 配置

nonisolated struct ThirdPartyModelConfig: Codable, Hashable, Sendable {
    var provider: ThirdPartyProvider = .openAICompatible
    /// 服务根地址；不含具体路径，由 adapter 拼接
    var baseURL: String = ThirdPartyProvider.openAICompatible.defaultBaseURL
    var modelName: String = ""
    /// 是否声明 .vision 能力。开启后小票/截图会走原图直传，绕开本地 OCR。
    /// 模型不支持视觉却打开会导致请求报错，所以默认关，由用户按自己的模型确认。
    var supportsVision: Bool = false
    /// 是否声明 .reasoning 能力，把 ContextOptions.reasoningLevel 映射成各家的推理档位参数
    var supportsReasoning: Bool = false
    var structuredOutputMode: StructuredOutputMode = .auto
    /// 单次请求超时（秒）。推理模型慢，默认给足。
    var timeout: Double = 90

    /// 配置是否填全到可以发请求。API Key 单独存 Keychain，不在这里判断。
    var isComplete: Bool {
        !modelName.trimmed.isEmpty && normalizedBaseURL != nil
    }

    /// 去掉尾部斜杠并校验成 URL；非法返回 nil
    var normalizedBaseURL: URL? {
        var text = baseURL.trimmed
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    /// 用于给「自动降级」的探测结果做缓存键：endpoint 或模型一变就重新探测
    var probeCacheKey: String {
        "\(provider.rawValue)|\(normalizedBaseURL?.absoluteString ?? "")|\(modelName.trimmed)"
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - 云端后端选择

/// 「使用云端模型」打开后，具体走哪条云端通道
nonisolated enum AICloudBackend: String, CaseIterable, Sendable {
    /// Apple Private Cloud Compute（默认，端到端加密，无需用户配置）
    case applePCC
    /// 用户自带的第三方 API
    case thirdParty
}

// MARK: - 持久化

/// 配置读写。刻意做成 nonisolated 静态方法：ReceiptParser 的模型选择路径
/// （activeCloudModel / isMultimodalAvailable）本身就是 nonisolated 的。
enum ThirdPartyModelStore {

    private static let configKey = "thirdPartyModelConfig"
    private static let backendKey = "aiCloudBackend"
    private static let probeModeKey = "thirdPartyResolvedStructuredMode"
    private static let probeKeyKey = "thirdPartyResolvedStructuredModeFor"

    // MARK: 配置

    static var config: ThirdPartyModelConfig {
        get {
            guard let data = UserDefaults.standard.data(forKey: configKey),
                  let decoded = try? JSONDecoder().decode(ThirdPartyModelConfig.self, from: data) else {
                return ThirdPartyModelConfig()
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    // MARK: 后端选择

    static var backend: AICloudBackend {
        get { AICloudBackend(rawValue: UserDefaults.standard.string(forKey: backendKey) ?? "") ?? .applePCC }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: backendKey) }
    }

    // MARK: API Key（Keychain）

    static var apiKey: String? {
        get { KeychainStore.read(.thirdPartyAPIKey) }
        set {
            if let newValue, !newValue.isEmpty {
                KeychainStore.save(newValue, for: .thirdPartyAPIKey)
            } else {
                KeychainStore.delete(.thirdPartyAPIKey)
            }
        }
    }

    static var hasAPIKey: Bool {
        !(apiKey?.isEmpty ?? true)
    }

    /// 第三方通道是否配置齐全、可以真的发请求
    static var isReady: Bool {
        config.isComplete && hasAPIKey
    }

    // MARK: 结构化输出降级探测结果

    /// 读取 .auto 模式下已探明的可用档位；换了 endpoint/模型则失效
    static func cachedStructuredMode(for config: ThirdPartyModelConfig) -> StructuredOutputMode? {
        guard UserDefaults.standard.string(forKey: probeKeyKey) == config.probeCacheKey,
              let raw = UserDefaults.standard.string(forKey: probeModeKey) else { return nil }
        return StructuredOutputMode(rawValue: raw)
    }

    static func cacheStructuredMode(_ mode: StructuredOutputMode, for config: ThirdPartyModelConfig) {
        UserDefaults.standard.set(config.probeCacheKey, forKey: probeKeyKey)
        UserDefaults.standard.set(mode.rawValue, forKey: probeModeKey)
    }

    static func clearStructuredModeCache() {
        UserDefaults.standard.removeObject(forKey: probeKeyKey)
        UserDefaults.standard.removeObject(forKey: probeModeKey)
    }
}
