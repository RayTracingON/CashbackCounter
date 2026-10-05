//
//  ClaudeModelCatalog.swift
//  CashbackCounter
//
//  内置「Claude」服务商 → Anthropic 官方 ClaudeForFoundationModels 包。
//
//  为什么 Claude 不走手写的 AnthropicAdapter：官方包按模型能力表决定发哪些字段
//  （adaptive thinking、effort、原生结构化输出 output_config.format……），
//  结构化输出和思考可以同时开；手写 adapter 只能用「强制工具调用」做结构化输出，
//  而强制工具调用和 extended thinking 在 Anthropic 侧互斥。
//  手写 adapter 仍然保留，给说 Anthropic 协议的自定义服务商（中转、兼容端点）用。
//
//  包源码内置在 Packages/ClaudeForFoundationModels（见那里的 VENDORED.md）。
//

import Foundation
import FoundationModels
import ClaudeForFoundationModels

@available(iOS 27.0, *)
nonisolated enum ClaudeModelCatalog {

    /// 包里编译进来的全部型号。ModelProviderPreset.claude.modelOptions 只是其中挑出来的几款，
    /// 有单测保证那边列出的每个 ID 都能在这里找到。
    static let knownModels: [ClaudeModel] = [
        .sonnet5_5, .opus5_5, .fable5_1, .fable5, .opus5, .sonnet5,
        .opus4_8, .opus4_7, .opus4_6, .sonnet4_6, .haiku4_5
    ]

    static func model(id: String) -> ClaudeModel? {
        knownModels.first { $0.id == id }
    }

    /// 服务商配置 + 密钥 → 官方包的 LanguageModel。模型 ID 不认识时返回 nil（调用方回退本地）
    static func languageModel(for provider: ModelProvider, apiKey: String) -> ClaudeLanguageModel? {
        guard let model = model(id: provider.config.modelName.trimmed) else { return nil }
        return ClaudeLanguageModel(
            name: model,
            auth: .apiKey(apiKey),
            timeout: provider.config.timeout
        )
    }
}
