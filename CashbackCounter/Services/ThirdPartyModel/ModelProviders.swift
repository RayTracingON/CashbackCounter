//
//  ModelProviders.swift
//  CashbackCounter
//
//  第三方「服务商」：内置预设（Claude / DeepSeek / OpenAI / Gemini）+ 用户自己添加的任意多个。
//
//  和 ThirdPartyAPIFormat 的区别：协议格式是「怎么说话」，服务商是「跟谁说话」。
//  DeepSeek 是服务商，说的是 OpenAI 兼容协议；用户自建的中转也是服务商，协议由用户选。
//
//  每个服务商各自记住自己的模型、能力开关和 API Key，切换服务商不用重填。
//  同一时刻只有一个「当前使用」的服务商，ReceiptParser 只认它。
//

import Foundation

// MARK: - 推荐模型

/// 预设里给出的推荐模型。只是快捷选项，除 Claude 外用户仍可手填别的模型名。
nonisolated struct ProviderModelOption: Hashable, Sendable, Identifiable {
    /// API 里的模型 ID
    let id: String
    /// 一句话说明，已本地化
    let note: String
    let supportsVision: Bool
    let supportsReasoning: Bool
}

// MARK: - 内置预设

nonisolated enum ModelProviderPreset: String, Codable, CaseIterable, Sendable {
    /// 走官方 ClaudeForFoundationModels 包（见 ClaudeModelCatalog），不走手写 adapter
    case claude
    /// OpenAI 兼容协议，但默认开思考、只支持 json_object，需要专门的开关
    case deepSeek
    case openAI
    case gemini

    var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .deepSeek: return "DeepSeek"
        case .openAI:   return "OpenAI"
        case .gemini:   return "Google Gemini"
        }
    }

    var systemImage: String {
        switch self {
        case .claude:   return "asterisk"
        case .deepSeek: return "fish.fill"
        case .openAI:   return "circle.hexagongrid.fill"
        case .gemini:   return "sparkle"
        }
    }

    var apiFormat: ThirdPartyAPIFormat {
        switch self {
        case .claude:            return .anthropic
        case .deepSeek, .openAI: return .openAICompatible
        case .gemini:            return .gemini
        }
    }

    /// 内置服务商的地址固定，不让用户改；要走代理/中转请添加自定义服务商
    var baseURL: String {
        switch self {
        case .claude:   return "https://api.anthropic.com"
        case .deepSeek: return "https://api.deepseek.com"
        case .openAI:   return "https://api.openai.com/v1"
        case .gemini:   return "https://generativelanguage.googleapis.com"
        }
    }

    /// 申请 API Key 的页面
    var apiKeyURL: URL? {
        switch self {
        case .claude:   return URL(string: "https://platform.claude.com/settings/keys")
        case .deepSeek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .openAI:   return URL(string: "https://platform.openai.com/api-keys")
        case .gemini:   return URL(string: "https://aistudio.google.com/apikey")
        }
    }

    /// 第一个是默认模型。截至 2026-10 各家文档的在售型号。
    /// ⚠️ Claude 的 ID 必须能被 ClaudeModelCatalog 识别（有单测兜着），
    /// 官方包靠模型能力表决定发哪些请求字段，猜错会直接 400。
    var modelOptions: [ProviderModelOption] {
        switch self {
        case .claude:
            return [
                .init(id: "claude-sonnet-5-5", note: String.loc("均衡，推荐"), supportsVision: true, supportsReasoning: true),
                .init(id: "claude-haiku-4-5", note: String.loc("最快最省"), supportsVision: true, supportsReasoning: false),
                .init(id: "claude-opus-5-5", note: String.loc("最强，较慢较贵"), supportsVision: true, supportsReasoning: true)
            ]
        case .deepSeek:
            return [
                .init(id: "deepseek-flash", note: String.loc("快，支持图片"), supportsVision: true, supportsReasoning: true),
                .init(id: "deepseek-v4-pro", note: String.loc("更强，不支持图片"), supportsVision: false, supportsReasoning: true)
            ]
        case .openAI:
            return [
                .init(id: "gpt-6-luna", note: String.loc("最快最省"), supportsVision: true, supportsReasoning: true),
                .init(id: "gpt-6.1-sol", note: String.loc("均衡"), supportsVision: true, supportsReasoning: true),
                .init(id: "gpt-6-astra", note: String.loc("最强，较慢较贵"), supportsVision: true, supportsReasoning: true)
            ]
        case .gemini:
            return [
                .init(id: "gemini-3.5-flash-lite", note: String.loc("最快最省"), supportsVision: true, supportsReasoning: true),
                .init(id: "gemini-3.8-flash", note: String.loc("均衡"), supportsVision: true, supportsReasoning: true),
                .init(id: "gemini-3.1-pro-preview", note: String.loc("最强（预览版）"), supportsVision: true, supportsReasoning: true)
            ]
        }
    }

    /// 只能从推荐列表里选模型（不能手填）。Claude 的能力表是编译进官方包的，
    /// 没登记过的 ID 无法安全构造请求。
    var restrictsModelChoice: Bool { self == .claude }

    var defaultConfig: ThirdPartyModelConfig {
        var config = ThirdPartyModelConfig()
        config.apiFormat = apiFormat
        config.baseURL = baseURL
        if let first = modelOptions.first {
            config.modelName = first.id
            config.supportsVision = first.supportsVision
        }
        // 推理默认关：小票解析要的是快，账单这类重活由用户自己决定要不要开
        config.supportsReasoning = false
        switch self {
        case .deepSeek:
            // 只认 json_object；直接定死，省掉自动降级时那次必然失败的 json_schema 探测
            config.structuredOutputMode = .jsonObject
            config.thinkingSwitch = .thinkingType
        case .claude, .openAI, .gemini:
            break
        }
        return config
    }

    /// 旧版单一配置迁移时用：地址、协议都对得上才认作这家
    func matches(legacy config: ThirdPartyModelConfig) -> Bool {
        guard config.apiFormat == apiFormat,
              let host = config.normalizedBaseURL?.host?.lowercased(),
              host == URL(string: baseURL)?.host?.lowercased() else { return false }
        if restrictsModelChoice {
            return modelOptions.contains { $0.id == config.modelName.trimmed }
        }
        return true
    }
}

// MARK: - 服务商

nonisolated struct ModelProvider: Codable, Hashable, Sendable, Identifiable {
    /// 内置：`builtin.<preset>`；自定义：UUID
    var id: String
    /// nil 表示用户自定义的服务商
    var preset: ModelProviderPreset?
    /// 只有自定义服务商用得上
    var customName: String = ""
    var config: ThirdPartyModelConfig

    var isCustom: Bool { preset == nil }

    var displayName: String {
        if let preset { return preset.displayName }
        let name = customName.trimmed
        if !name.isEmpty { return name }
        return config.normalizedBaseURL?.host ?? String.loc("未命名服务商")
    }

    var systemImage: String { preset?.systemImage ?? "server.rack" }

    /// 地址、模型名齐全，可以发请求（密钥另算，见 ThirdPartyModelStore.isReady）
    var isComplete: Bool {
        guard config.isComplete else { return false }
        if let preset, preset.restrictsModelChoice {
            return preset.modelOptions.contains { $0.id == config.modelName.trimmed }
        }
        return true
    }

    static func builtIn(_ preset: ModelProviderPreset) -> ModelProvider {
        ModelProvider(id: "builtin.\(preset.rawValue)", preset: preset, config: preset.defaultConfig)
    }

    static func newCustom() -> ModelProvider {
        var config = ThirdPartyModelConfig()
        config.baseURL = ""
        return ModelProvider(id: UUID().uuidString, preset: nil, config: config)
    }

    /// 内置服务商的协议、地址、思考开关以预设为准：每次读出来都覆盖一遍，
    /// 以后预设改了地址，老用户存下的值也会跟着生效。
    func normalized() -> ModelProvider {
        guard let preset else { return self }
        var copy = self
        let defaults = preset.defaultConfig
        copy.config.apiFormat = defaults.apiFormat
        copy.config.baseURL = defaults.baseURL
        copy.config.thinkingSwitch = defaults.thinkingSwitch
        return copy
    }

    /// 旧版单一配置 → 服务商。地址能对上某个预设就并入那家内置服务商，否则当作自定义。
    static func migrated(from legacy: ThirdPartyModelConfig) -> ModelProvider {
        if let preset = ModelProviderPreset.allCases.first(where: { $0.matches(legacy: legacy) }) {
            var provider = ModelProvider.builtIn(preset)
            if !legacy.modelName.trimmed.isEmpty {
                provider.config.modelName = legacy.modelName.trimmed
            }
            provider.config.supportsVision = legacy.supportsVision
            provider.config.supportsReasoning = legacy.supportsReasoning
            provider.config.timeout = legacy.timeout
            // 用户手动指定过档位就保留；.auto 则用预设的（DeepSeek 预设是 json_object）
            if legacy.structuredOutputMode != .auto {
                provider.config.structuredOutputMode = legacy.structuredOutputMode
            }
            return provider.normalized()
        }
        var custom = ModelProvider.newCustom()
        custom.config = legacy
        custom.customName = legacy.normalizedBaseURL?.host ?? ""
        return custom
    }

    private enum CodingKeys: String, CodingKey {
        case id, preset, customName, config
    }

    init(id: String, preset: ModelProviderPreset?, customName: String = "", config: ThirdPartyModelConfig) {
        self.id = id
        self.preset = preset
        self.customName = customName
        self.config = config
    }

    /// 同 ThirdPartyModelConfig：容忍缺键，以后加字段不会把老数据读丢
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        preset = try container.decodeIfPresent(ModelProviderPreset.self, forKey: .preset)
        customName = try container.decodeIfPresent(String.self, forKey: .customName) ?? ""
        config = try container.decodeIfPresent(ThirdPartyModelConfig.self, forKey: .config) ?? ThirdPartyModelConfig()
    }
}

// MARK: - 持久化

/// 服务商配置读写。刻意做成 nonisolated 静态方法：ReceiptParser 的模型选择路径
/// （activeCloudRoute / isMultimodalAvailable）本身就是 nonisolated 的。
///
/// 服务商本体（地址 / 模型 / 能力开关）是普通偏好，放 UserDefaults；
/// API Key 按服务商分条存 Keychain（见 KeychainStore 顶部关于明文 plist 的说明）。
nonisolated enum ThirdPartyModelStore {

    /// 任何服务商配置、当前选择或密钥变动都会 +1。
    /// 设置页用 @AppStorage 观察它来刷新——Keychain 的变动 SwiftUI 是看不见的。
    static let revisionKey = "thirdPartyProvidersRevision"

    private static let providersKey = "thirdPartyProviders"
    private static let activeProviderKey = "thirdPartyActiveProviderID"
    private static let backendKey = "aiCloudBackend"
    private static let probeCacheKey = "thirdPartyResolvedStructuredModes"

    // 旧版单一配置
    private static let legacyConfigKey = "thirdPartyModelConfig"
    private static let legacyProbeModeKey = "thirdPartyResolvedStructuredMode"
    private static let legacyProbeKeyKey = "thirdPartyResolvedStructuredModeFor"

    private static var defaults: UserDefaults { .standard }

    // MARK: 后端选择

    static var backend: AICloudBackend {
        get { AICloudBackend(rawValue: defaults.string(forKey: backendKey) ?? "") ?? .applePCC }
        set { defaults.set(newValue.rawValue, forKey: backendKey) }
    }

    // MARK: 服务商列表

    /// 内置四家固定在前（顺序同 ModelProviderPreset.allCases），自定义的按添加顺序排在后面
    static var providers: [ModelProvider] {
        migrateIfNeeded()
        let stored = loadStored()
        let builtIns = ModelProviderPreset.allCases.map { preset in
            stored.first { $0.preset == preset }?.normalized() ?? .builtIn(preset)
        }
        return builtIns + stored.filter(\.isCustom)
    }

    static func provider(id: String) -> ModelProvider? {
        providers.first { $0.id == id }
    }

    /// 新增或更新
    static func save(_ provider: ModelProvider) {
        migrateIfNeeded()
        var stored = loadStored()
        if let index = stored.firstIndex(where: { $0.id == provider.id }) {
            stored[index] = provider
        } else {
            stored.append(provider)
        }
        writeStored(stored)
    }

    /// 只能删自定义服务商；连同它的密钥一起删，正在使用的话退回「未选择」
    static func delete(providerID: String) {
        var stored = loadStored()
        guard let index = stored.firstIndex(where: { $0.id == providerID }),
              stored[index].isCustom else { return }
        stored.remove(at: index)
        writeStored(stored)
        KeychainStore.delete(account: KeychainStore.thirdPartyAPIKeyAccount(providerID: providerID))
        if activeProviderID == providerID { activeProviderID = nil }
    }

    // MARK: 当前使用

    static var activeProviderID: String? {
        get {
            migrateIfNeeded()
            return defaults.string(forKey: activeProviderKey)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: activeProviderKey)
            } else {
                defaults.removeObject(forKey: activeProviderKey)
            }
            bumpRevision()
        }
    }

    static var activeProvider: ModelProvider? {
        activeProviderID.flatMap(provider(id:))
    }

    /// 当前服务商是否配置齐全、可以真的发请求
    static var isReady: Bool {
        activeProvider.map(isReady) ?? false
    }

    static func isReady(_ provider: ModelProvider) -> Bool {
        provider.isComplete && hasAPIKey(for: provider.id)
    }

    // MARK: API Key（Keychain，按服务商分条）

    static func apiKey(for providerID: String) -> String? {
        migrateIfNeeded()
        return KeychainStore.read(account: KeychainStore.thirdPartyAPIKeyAccount(providerID: providerID))
    }

    static func setAPIKey(_ key: String?, for providerID: String) {
        let account = KeychainStore.thirdPartyAPIKeyAccount(providerID: providerID)
        if let key = key?.trimmed, !key.isEmpty {
            KeychainStore.save(key, account: account)
        } else {
            KeychainStore.delete(account: account)
        }
        bumpRevision()
    }

    static func hasAPIKey(for providerID: String) -> Bool {
        !(apiKey(for: providerID)?.isEmpty ?? true)
    }

    // MARK: 结构化输出降级探测结果

    /// 读取 .auto 模式下已探明的可用档位。按 协议+地址+模型 分别记，
    /// 多个服务商之间来回切换不会互相冲掉；换了 endpoint/模型自然失效。
    static func cachedStructuredMode(for config: ThirdPartyModelConfig) -> StructuredOutputMode? {
        let cache = defaults.dictionary(forKey: probeCacheKey) as? [String: String]
        return cache?[config.probeCacheKey].flatMap(StructuredOutputMode.init(rawValue:))
    }

    static func cacheStructuredMode(_ mode: StructuredOutputMode, for config: ThirdPartyModelConfig) {
        var cache = defaults.dictionary(forKey: probeCacheKey) as? [String: String] ?? [:]
        cache[config.probeCacheKey] = mode.rawValue
        defaults.set(cache, forKey: probeCacheKey)
    }

    static func clearStructuredModeCache(for config: ThirdPartyModelConfig) {
        guard var cache = defaults.dictionary(forKey: probeCacheKey) as? [String: String] else { return }
        cache.removeValue(forKey: config.probeCacheKey)
        defaults.set(cache, forKey: probeCacheKey)
    }

    // MARK: 存储细节

    private static func loadStored() -> [ModelProvider] {
        guard let data = defaults.data(forKey: providersKey),
              let decoded = try? JSONDecoder().decode([ModelProvider].self, from: data) else { return [] }
        return decoded
    }

    private static func writeStored(_ providers: [ModelProvider]) {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: providersKey)
        bumpRevision()
    }

    private static func bumpRevision() {
        defaults.set(defaults.integer(forKey: revisionKey) &+ 1, forKey: revisionKey)
    }

    // MARK: 旧版迁移

    /// 旧版只有一份配置 + 一把密钥。首次读取新结构时搬过来并设为当前服务商。
    /// 以「新结构的键是否存在」为界，只跑一次；写入新键放在最前，避免读写互相递归。
    static func migrateIfNeeded() {
        guard defaults.object(forKey: providersKey) == nil else { return }
        let legacyKey = KeychainStore.read(.thirdPartyAPIKey)?.trimmed
        let legacyConfig = defaults.data(forKey: legacyConfigKey)
            .flatMap { try? JSONDecoder().decode(ThirdPartyModelConfig.self, from: $0) }

        // 从没配过（或只开过页面没填东西）就不造一个空的自定义服务商出来
        let hasKey = !(legacyKey?.isEmpty ?? true)
        guard let legacyConfig, hasKey || legacyConfig.isComplete else {
            writeStored([])
            cleanUpLegacy()
            return
        }

        let provider = ModelProvider.migrated(from: legacyConfig)
        writeStored([provider])
        if let legacyKey, hasKey {
            KeychainStore.save(legacyKey, account: KeychainStore.thirdPartyAPIKeyAccount(providerID: provider.id))
        }
        defaults.set(provider.id, forKey: activeProviderKey)
        cleanUpLegacy()
        print("🔁 第三方模型配置已迁移为服务商「\(provider.displayName)」")
    }

    private static func cleanUpLegacy() {
        KeychainStore.delete(.thirdPartyAPIKey)
        defaults.removeObject(forKey: legacyConfigKey)
        defaults.removeObject(forKey: legacyProbeModeKey)
        defaults.removeObject(forKey: legacyProbeKeyKey)
    }
}
