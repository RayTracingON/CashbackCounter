//
//  ModelListFetcher.swift
//  CashbackCounter
//
//  从服务端拉取可用模型列表，省得用户去服务商文档里抄模型名。
//
//  三家协议各有一个列表接口：
//  - OpenAI 兼容：GET {base}/models（OpenRouter、硅基流动、Ollama、LM Studio 等都实现了）
//  - Anthropic：GET {base}/v1/models
//  - Gemini：GET {base}/v1beta/models
//  和聊天请求一样把「拼请求」和「解析」拆开，不联网也能单测。
//  只取第一页：limit / pageSize 都给到 1000，个人账号碰不到翻页。
//

import Foundation

/// 服务端列出的一个模型
nonisolated struct RemoteModel: Hashable, Sendable, Identifiable {
    let id: String
    /// 服务端给的展示名（Anthropic display_name、Gemini displayName、OpenRouter name）；和 id 相同时不存
    let displayName: String?
    /// 是否支持图片输入。只有服务端明确说了才有值（目前只有 OpenRouter 给 input_modalities），
    /// nil 表示不知道，选中时不去改用户的图像识别开关
    let supportsVision: Bool?
}

/// 拉列表的请求：只有 GET，没有请求体
struct ModelListRequest: Sendable {
    var url: URL
    var headers: [String: String]
}

enum ModelListFetcher {

    /// 列表接口应该很快，不跟聊天请求共用那个给推理模型留足的超时
    private static let maxTimeout: Double = 30

    static func fetch(config: ThirdPartyModelConfig, apiKey: String) async throws -> [RemoteModel] {
        let request = try makeRequest(config: config, apiKey: apiKey)
        let json = try await ThirdPartyHTTP.get(
            url: request.url,
            headers: request.headers,
            timeout: min(config.timeout, maxTimeout)
        )
        return decode(json, format: config.apiFormat)
    }

    // MARK: - 拼请求

    static func makeRequest(config: ThirdPartyModelConfig, apiKey: String) throws -> ModelListRequest {
        guard let base = config.normalizedBaseURL else { throw ThirdPartyModelError.invalidBaseURL }
        let key = apiKey.trimmed

        switch config.apiFormat {
        case .openAICompatible:
            return ModelListRequest(
                url: base.appending(path: "models"),
                headers: OpenAICompatibleAdapter.authHeaders(apiKey: key)
            )
        case .anthropic:
            return ModelListRequest(
                url: base.appending(path: "v1/models")
                    .appending(queryItems: [URLQueryItem(name: "limit", value: "1000")]),
                headers: AnthropicAdapter.authHeaders(apiKey: key)
            )
        case .gemini:
            return ModelListRequest(
                url: base.appending(path: "v1beta/models")
                    .appending(queryItems: [URLQueryItem(name: "pageSize", value: "1000")]),
                headers: GeminiAdapter.authHeaders(apiKey: key)
            )
        }
    }

    // MARK: - 解析

    /// 解析失败或格式不认识时返回空数组，由调用方提示「没拿到模型」
    static func decode(_ json: [String: Any], format: ThirdPartyAPIFormat) -> [RemoteModel] {
        let models: [RemoteModel]
        switch format {
        case .openAICompatible:
            models = (json["data"] as? [[String: Any]] ?? []).compactMap(openAIModel)
                .filter { isLikelyChatModel($0.id) }
        case .anthropic:
            models = (json["data"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return RemoteModel(id: id, displayName: distinctName(item["display_name"], from: id), supportsVision: nil)
            }
        case .gemini:
            models = (json["models"] as? [[String: Any]] ?? []).compactMap(geminiModel)
        }

        // 去重 + 按 id 排序：OpenAI 兼容服务返回的顺序基本是随机的，几百个模型不排序没法找
        var seen = Set<String>()
        return models
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func openAIModel(_ item: [String: Any]) -> RemoteModel? {
        guard let id = item["id"] as? String, !id.trimmed.isEmpty else { return nil }
        // OpenRouter 扩展字段：architecture.input_modalities 里有 "image" 就是能看图
        let modalities = (item["architecture"] as? [String: Any])?["input_modalities"] as? [String]
        return RemoteModel(
            id: id,
            displayName: distinctName(item["name"], from: id),
            supportsVision: modalities.map { $0.contains("image") }
        )
    }

    private static func geminiModel(_ item: [String: Any]) -> RemoteModel? {
        guard let name = item["name"] as? String else { return nil }
        // 嵌入模型等不支持 generateContent，选了也用不了
        if let methods = item["supportedGenerationMethods"] as? [String],
           !methods.contains("generateContent") {
            return nil
        }
        // 接口返回 "models/gemini-x"，而请求路径里 App 会自己补 models/ 前缀
        let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        return RemoteModel(id: id, displayName: distinctName(item["displayName"], from: id), supportsVision: nil)
    }

    private static func distinctName(_ value: Any?, from id: String) -> String? {
        guard let name = (value as? String)?.trimmed, !name.isEmpty, name != id else { return nil }
        return name
    }

    /// OpenAI 兼容的 /models 会把嵌入、语音、生图、审核、重排模型一起列出来。
    /// 只剔除名字上一眼能认出来的这几类，宁可多留也不误删——列表有搜索。
    private static let nonChatMarkers = [
        "embed", "whisper", "tts", "dall-e", "moderation", "rerank", "transcribe"
    ]

    static func isLikelyChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return !nonChatMarkers.contains { lowered.contains($0) }
    }
}
