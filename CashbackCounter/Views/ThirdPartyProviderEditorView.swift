//
//  ThirdPartyProviderEditorView.swift
//  CashbackCounter
//
//  单个第三方服务商的配置页（内置预设和自定义服务商共用）。
//

import SwiftUI
import FoundationModels
import ClaudeForFoundationModels

/// 连接测试用的最小 @Generable 结构。
/// 用真的 schema 而不是随便发一句 "hi"：这样一次测试就同时验证了
/// 鉴权、endpoint、模型名、**以及结构化输出**——最后这项才是最容易在
/// 自建/中转服务上翻车的地方，而且测完顺带把降级探测结果缓存下来。
@Generable
private struct ConnectionProbe {
    @Guide(description: "Always exactly the two letters: OK")
    var status: String

    @Guide(description: "The name of the model answering this request.")
    var model: String?
}

@available(iOS 27.0, *)
struct ThirdPartyProviderEditorView: View {

    @State private var provider: ModelProvider
    @State private var apiKey: String
    @State private var testState: TestState = .idle
    @State private var showDeleteConfirmation = false
    @State private var modelListState: ModelListState = .idle
    @State private var fetchedModels: [RemoteModel] = []
    @State private var showModelList = false
    @FocusState private var keyFieldFocused: Bool
    /// 观察存储版本号：「当前使用」可能在别处被改，Keychain 变动 SwiftUI 也看不见
    @AppStorage(ThirdPartyModelStore.revisionKey) private var storeRevision = 0
    @Environment(\.dismiss) private var dismiss

    enum TestState: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    enum ModelListState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// 新建的自定义服务商也从这里进来：在用户真正改动之前不落盘，
    /// 点进来又直接返回不会留下一条空的「未命名服务商」。
    init(provider: ModelProvider) {
        _provider = State(initialValue: provider)
        _apiKey = State(initialValue: ThirdPartyModelStore.apiKey(for: provider.id) ?? "")
    }

    var body: some View {
        Form {
            activationSection
            if provider.isCustom {
                identitySection
            }
            modelSection
            credentialsSection
            if provider.preset == .claude {
                claudeCapabilitiesSection
            } else {
                capabilitiesSection
            }
            advancedSection
            testSection
            privacySection
            if provider.isCustom {
                deleteSection
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: provider) { oldValue, newValue in
            ThirdPartyModelStore.save(newValue)
            // 换了地址/模型/输出档位，之前探明的结构化输出能力就不再作数
            ThirdPartyModelStore.clearStructuredModeCache(for: oldValue.config)
            testState = .idle
            // 换了地址或协议，上次拉列表的报错就不再相关
            if oldValue.config.apiFormat != newValue.config.apiFormat
                || oldValue.config.baseURL != newValue.config.baseURL {
                modelListState = .idle
            }
        }
        .onChange(of: apiKey) { _, newValue in
            ThirdPartyModelStore.setAPIKey(newValue, for: provider.id)
            // 还没选过任何服务商时，第一个填完整的直接设为当前，省用户一步
            if ThirdPartyModelStore.activeProviderID == nil, isReady {
                ThirdPartyModelStore.save(provider)
                ThirdPartyModelStore.activeProviderID = provider.id
            }
            testState = .idle
        }
        .confirmationDialog(
            "删除「\(provider.displayName)」？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除服务商", role: .destructive) {
                ThirdPartyModelStore.delete(providerID: provider.id)
                dismiss()
            }
        } message: {
            Text("保存在钥匙串里的 API 密钥会一并删除。")
        }
        .sheet(isPresented: $showModelList) {
            RemoteModelListView(
                models: fetchedModels,
                selectedID: provider.config.modelName.trimmed
            ) { model in
                apply(model)
            }
        }
    }

    private var isActive: Bool {
        _ = storeRevision
        return ThirdPartyModelStore.activeProviderID == provider.id
    }

    private var isReady: Bool {
        provider.isComplete && !apiKey.trimmed.isEmpty
    }

    // MARK: - 启用

    private var activationSection: some View {
        Section {
            if isActive {
                Label("正在使用此服务商", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    // 内置服务商可能还没落过盘（一直用的默认值），先存一份再设为当前
                    ThirdPartyModelStore.save(provider)
                    ThirdPartyModelStore.activeProviderID = provider.id
                } label: {
                    Label("使用此服务商", systemImage: "checkmark.circle")
                }
                .disabled(!isReady)
            }
        } footer: {
            if !isReady {
                Text("填好模型和 API 密钥后才能使用。")
            }
        }
    }

    // MARK: - 自定义服务商：名称 / 协议 / 地址

    private var identitySection: some View {
        Section {
            LabeledContent("名称") {
                TextField(String.loc("例如：公司中转"), text: $provider.customName)
                    .multilineTextAlignment(.trailing)
            }

            Picker("协议格式", selection: $provider.config.apiFormat) {
                ForEach(ThirdPartyAPIFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }

            LabeledContent("API 地址") {
                TextField(provider.config.apiFormat.defaultBaseURL, text: $provider.config.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("服务商")
        } footer: {
            Text(provider.config.apiFormat.hint)
        }
    }

    // MARK: - 模型

    @ViewBuilder
    private var modelSection: some View {
        let options = provider.preset?.modelOptions ?? []
        Section {
            if provider.preset?.restrictsModelChoice == true {
                // Claude：官方包按编译进来的能力表构造请求，只能从已登记的型号里选
                Picker("模型", selection: $provider.config.modelName) {
                    ForEach(options) { option in
                        VStack(alignment: .leading) {
                            Text(option.id)
                            Text(option.note).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(option.id)
                    }
                }
                .pickerStyle(.navigationLink)
            } else {
                LabeledContent("模型名称") {
                    TextField(
                        options.first?.id ?? provider.config.apiFormat.defaultModelName,
                        text: $provider.config.modelName
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                }

                ForEach(options) { option in
                    Button {
                        apply(option)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.id).foregroundStyle(.primary)
                                Text(option.note).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if provider.config.modelName.trimmed == option.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }

                Button {
                    keyFieldFocused = false
                    fetchModels()
                } label: {
                    HStack {
                        if modelListState == .loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        Text(modelListState == .loading ? "正在获取…" : "从服务获取模型列表")
                    }
                }
                .disabled(modelListState == .loading || provider.config.normalizedBaseURL == nil)

                if case .failed(let message) = modelListState {
                    Label {
                        Text(message).font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("模型")
        } footer: {
            if provider.preset?.restrictsModelChoice != true {
                if options.isEmpty {
                    Text("可以从服务获取可用模型，也可以直接填写模型名。")
                } else {
                    Text("点选推荐模型会同时按它的能力设置图像识别；也可以直接填写其他模型名。")
                }
            }
        }
    }

    /// 选推荐模型时顺带把能力开关对齐：图像识别跟模型走；模型不支持推理就关掉推理
    private func apply(_ option: ProviderModelOption) {
        provider.config.modelName = option.id
        provider.config.supportsVision = option.supportsVision
        if !option.supportsReasoning {
            provider.config.supportsReasoning = false
        }
    }

    /// 从服务端列表里选的模型：只有服务端明确说了能不能看图，才去动图像识别开关
    private func apply(_ model: RemoteModel) {
        provider.config.modelName = model.id
        if let supportsVision = model.supportsVision {
            provider.config.supportsVision = supportsVision
        }
    }

    private func fetchModels() {
        let config = provider.config
        let key = apiKey.trimmed
        modelListState = .loading

        Task {
            let state: ModelListState
            var models: [RemoteModel] = []
            do {
                models = try await ModelListFetcher.fetch(config: config, apiKey: key)
                state = models.isEmpty
                    ? .failed(String.loc("服务没有返回可用的模型，请直接填写模型名。"))
                    : .idle
            } catch ThirdPartyModelError.httpError(let status, _) where status == 404 || status == 405 {
                // 不少中转/自建服务只实现了 chat/completions，没有列表接口
                state = .failed(String.loc("该服务没有提供模型列表接口，请直接填写模型名。"))
            } catch {
                state = .failed(error.localizedDescription)
            }
            await MainActor.run {
                modelListState = state
                fetchedModels = models
                showModelList = !models.isEmpty
            }
        }
    }

    // MARK: - 连接信息

    private var credentialsSection: some View {
        Section {
            if let preset = provider.preset {
                LabeledContent("API 地址") {
                    Text(preset.baseURL)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            LabeledContent("API 密钥") {
                SecureField("必填", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .focused($keyFieldFocused)
            }

            if !apiKey.isEmpty {
                Button(role: .destructive) {
                    apiKey = ""
                } label: {
                    Label("清除密钥", systemImage: "trash")
                }
            }

            if let url = provider.preset?.apiKeyURL {
                Link(destination: url) {
                    Label("获取 API 密钥", systemImage: "arrow.up.right.square")
                }
            }
        } header: {
            Text("连接信息")
        } footer: {
            Text("密钥保存在设备的钥匙串（Keychain）中，不会同步到 iCloud，也不会发送给本 App 的服务器。")
        }
    }

    // MARK: - 能力

    private var capabilitiesSection: some View {
        Section {
            Toggle(isOn: $provider.config.supportsVision) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("图像识别")
                    Text("开启后小票和截图直接发原图，跳过本地 OCR")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $provider.config.supportsReasoning) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("推理模式")
                    Text("按场景自动调节思考强度，账单和图片解析更准，但更慢更贵")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("模型能力")
        } footer: {
            Text("请按你所选模型的实际能力勾选。为不支持的模型开启这些选项会导致请求失败。")
        }
    }

    /// Claude 的能力由官方包的型号表决定，这里只展示
    private var claudeCapabilitiesSection: some View {
        let capabilities = ClaudeModelCatalog.model(id: provider.config.modelName.trimmed)?.capabilities
        return Section {
            // 三元表达式里的字面量会被推断成 String 而不走本地化，所以显式 String.loc
            LabeledContent("图像识别") {
                Text(capabilities?.imageInput == true ? String.loc("支持") : String.loc("不支持"))
            }
            LabeledContent("推理") {
                Text(capabilities?.adaptiveThinking == true ? String.loc("按场景自动调节") : String.loc("不支持"))
            }
        } header: {
            Text("模型能力")
        } footer: {
            Text("Claude 通过 Anthropic 官方的 Foundation Models 接入包调用，模型能力由官方包自动识别，无需手动设置。")
        }
    }

    // MARK: - 高级

    private var advancedSection: some View {
        Section {
            if provider.preset != .claude {
                Picker("结构化输出", selection: $provider.config.structuredOutputMode) {
                    ForEach(StructuredOutputMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            // 内置 DeepSeek 已固定好；自定义的 OpenAI 兼容服务（比如智谱、DeepSeek 中转）才需要选
            if provider.isCustom, provider.config.apiFormat == .openAICompatible {
                Picker("思考开关", selection: $provider.config.thinkingSwitch) {
                    ForEach(ThinkingSwitch.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }

            LabeledContent("超时") {
                Text("\(Int(provider.config.timeout)) 秒")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $provider.config.timeout, in: 15...180, step: 15)
        } header: {
            Text("高级")
        } footer: {
            if provider.preset != .claude {
                Text("「自动」会先尝试 JSON Schema，服务不支持时自动降级到 JSON 模式或纯提示词约束，并记住结果。只有在自动探测判断有误时才需要手动指定。")
            }
        }
    }

    // MARK: - 连接测试

    private var testSection: some View {
        Section {
            Button {
                keyFieldFocused = false
                runTest()
            } label: {
                HStack {
                    if testState == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal.circle")
                    }
                    Text(testState == .running ? "测试中…" : "测试连接")
                }
            }
            .disabled(testState == .running || !isReady)

            switch testState {
            case .success(let message):
                Label {
                    Text(message).font(.footnote)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .failure(let message):
                Label {
                    Text(message).font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            case .idle, .running:
                EmptyView()
            }
        } footer: {
            Text("测试会发一次极小的结构化请求，用来验证地址、密钥、模型名以及该服务对 JSON Schema 的支持程度。")
        }
    }

    // MARK: - 隐私说明

    private var privacySection: some View {
        Section {
            Label {
                Text(privacyNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
        }
    }

    private var privacyNotice: String {
        let host = provider.config.normalizedBaseURL?.host ?? String.loc("你填写的服务地址")
        return String.loc("使用「\(provider.displayName)」时，小票文字、截图和账单内容会发送到 \(host)。这些数据的处理方式由该服务商决定，不再受 Apple 私有云计算的隐私保证覆盖。")
    }

    // MARK: - 删除

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("删除服务商", systemImage: "trash")
            }
        }
    }

    // MARK: - 动作

    private func runTest() {
        let provider = self.provider
        let key = apiKey.trimmed
        testState = .running

        Task {
            let result: TestState
            do {
                result = provider.preset == .claude
                    ? try await Self.testClaude(provider, apiKey: key)
                    : try await Self.testChatAdapter(provider.config, apiKey: key)
            } catch {
                result = .failure(error.localizedDescription)
            }
            await MainActor.run { testState = result }
        }
    }

    /// Claude 走完整的 LanguageModelSession → 官方包路径，和真实解析时一模一样
    private static func testClaude(_ provider: ModelProvider, apiKey: String) async throws -> TestState {
        guard let model = ClaudeModelCatalog.languageModel(for: provider, apiKey: apiKey) else {
            return .failure(String.loc("无法识别的 Claude 模型：\(provider.config.modelName)"))
        }
        let session = LanguageModelSession(
            model: model,
            instructions: "You are a connectivity probe. Reply with the requested JSON only."
        )
        let response = try await session.respond(to: "Report status OK.", generating: ConnectionProbe.self)
        guard !response.content.status.trimmed.isEmpty else {
            return .failure(String.loc("连接成功，但返回的不是预期的 JSON"))
        }
        return .success(String.loc("连接正常，\(model.model.id) 已返回结构化结果。"))
    }

    /// 其余服务商直接打 adapter：能顺带拿到降级探测结果和 token 用量给用户看
    private static func testChatAdapter(_ config: ThirdPartyModelConfig, apiKey: String) async throws -> TestState {
        let schema = try SchemaJSON.from(ConnectionProbe.generationSchema)
        let prompt = ChatPrompt(
            system: "You are a connectivity probe. Reply with the requested JSON only.",
            messages: [ChatMessage(role: .user, parts: [.text("Report status OK.")])]
        )
        let completion = try await ThirdPartyChatClient.complete(
            prompt: prompt,
            schema: schema,
            schemaName: "ConnectionProbe",
            tuning: ChatTuning(temperature: nil, maxTokens: 256, reasoning: nil),
            config: config,
            apiKey: apiKey
        )

        let cleaned = JSONResponseExtractor.extract(from: completion.text)
        guard let data = cleaned.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] != nil else {
            return .failure(String.loc(
                "连接成功，但返回的不是预期的 JSON：\(String(cleaned.prefix(120)))"
            ))
        }

        let resolved = ThirdPartyModelStore.cachedStructuredMode(for: config) ?? config.structuredOutputMode
        return .success(String.loc(
            "连接正常。结构化输出档位：\(resolved.displayName)，本次消耗 \(completion.inputTokens + completion.outputTokens) tokens。"
        ))
    }
}

// MARK: - 服务端模型列表

/// 拉回来的模型列表。OpenRouter 这类聚合服务一次能列出几百个，必须能搜
private struct RemoteModelListView: View {
    let models: [RemoteModel]
    let selectedID: String
    let onSelect: (RemoteModel) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [RemoteModel] {
        let keyword = query.trimmed
        guard !keyword.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(keyword)
                || ($0.displayName?.localizedCaseInsensitiveContains(keyword) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filtered) { model in
                        Button {
                            onSelect(model)
                            dismiss()
                        } label: {
                            row(model)
                        }
                    }
                } footer: {
                    Text("共 \(models.count) 个模型")
                }
            }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索模型")
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func row(_ model: RemoteModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.id)
                    .foregroundStyle(.primary)
                if let name = model.displayName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.supportsVision == true {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("支持图片")
            }
            if model.id == selectedID {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("内置：DeepSeek") {
    if #available(iOS 27.0, *) {
        NavigationStack {
            ThirdPartyProviderEditorView(provider: .builtIn(.deepSeek))
        }
    }
}

#Preview("内置：Claude") {
    if #available(iOS 27.0, *) {
        NavigationStack {
            ThirdPartyProviderEditorView(provider: .builtIn(.claude))
        }
    }
}

#Preview("服务端模型列表") {
    RemoteModelListView(
        models: [
            RemoteModel(id: "anthropic/claude-sonnet-5.5", displayName: "Anthropic: Claude Sonnet 5.5", supportsVision: true),
            RemoteModel(id: "deepseek/deepseek-v4-pro", displayName: "DeepSeek: V4 Pro", supportsVision: false),
            RemoteModel(id: "qwen/qwen3-vl-plus", displayName: nil, supportsVision: true)
        ],
        selectedID: "deepseek/deepseek-v4-pro"
    ) { _ in }
}

#Preview("自定义服务商") {
    if #available(iOS 27.0, *) {
        NavigationStack {
            ThirdPartyProviderEditorView(provider: .newCustom())
        }
    }
}
#endif
