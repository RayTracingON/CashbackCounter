//
//  ThirdPartyModelSettingsView.swift
//  CashbackCounter
//
//  第三方模型 API 的配置界面。
//

import SwiftUI
import FoundationModels

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
struct ThirdPartyModelSettingsView: View {

    @State private var config = ThirdPartyModelStore.config
    @State private var apiKey = ThirdPartyModelStore.apiKey ?? ""
    @State private var testState: TestState = .idle
    @FocusState private var keyFieldFocused: Bool

    enum TestState: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            providerSection
            credentialsSection
            capabilitiesSection
            advancedSection
            testSection
            privacySection
        }
        .navigationTitle("自定义 API")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: config) { _, newValue in
            ThirdPartyModelStore.config = newValue
            // 换了服务商/模型/输出档位，之前探明的结构化输出能力就不再作数
            ThirdPartyModelStore.clearStructuredModeCache()
            testState = .idle
        }
        .onChange(of: apiKey) { _, newValue in
            ThirdPartyModelStore.apiKey = newValue.trimmed
            testState = .idle
        }
    }

    // MARK: - 服务商

    private var providerSection: some View {
        Section {
            Picker("协议格式", selection: $config.provider) {
                ForEach(ThirdPartyProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .onChange(of: config.provider) { oldValue, newValue in
                // 地址还停在上一家的默认值时才帮忙换掉，别覆盖用户手填的
                if config.baseURL.trimmed.isEmpty || config.baseURL.trimmed == oldValue.defaultBaseURL {
                    config.baseURL = newValue.defaultBaseURL
                }
            }
        } header: {
            Text("服务商")
        } footer: {
            Text(config.provider.hint)
        }
    }

    // MARK: - 凭据

    private var credentialsSection: some View {
        Section {
            LabeledContent("API 地址") {
                TextField(config.provider.defaultBaseURL, text: $config.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("模型名称") {
                TextField(config.provider.defaultModelName, text: $config.modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
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
        } header: {
            Text("连接信息")
        } footer: {
            Text("密钥保存在设备的钥匙串（Keychain）中，不会同步到 iCloud，也不会发送给本 App 的服务器。")
        }
    }

    // MARK: - 能力

    private var capabilitiesSection: some View {
        Section {
            Toggle(isOn: $config.supportsVision) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("图像识别")
                    Text("开启后小票和截图直接发原图，跳过本地 OCR")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $config.supportsReasoning) {
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

    // MARK: - 高级

    private var advancedSection: some View {
        Section {
            Picker("结构化输出", selection: $config.structuredOutputMode) {
                ForEach(StructuredOutputMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            LabeledContent("超时") {
                Text("\(Int(config.timeout)) 秒")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $config.timeout, in: 15...180, step: 15)
        } header: {
            Text("高级")
        } footer: {
            Text("「自动」会先尝试 JSON Schema，服务不支持时自动降级到 JSON 模式或纯提示词约束，并记住结果。只有在自动探测判断有误时才需要手动指定。")
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
            .disabled(testState == .running || !canTest)

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
                Text("使用自定义 API 时，小票文字、截图和账单内容会发送到你填写的服务地址。这些数据的处理方式由该服务商决定，不再受 Apple Private Cloud Compute 的隐私保证覆盖。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 动作

    private var canTest: Bool {
        config.isComplete && !apiKey.trimmed.isEmpty
    }

    private func runTest() {
        let config = self.config
        let key = apiKey.trimmed
        testState = .running

        Task {
            do {
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
                    apiKey: key
                )

                let cleaned = JSONResponseExtractor.extract(from: completion.text)
                guard let data = cleaned.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["status"] != nil else {
                    await MainActor.run {
                        testState = .failure(String.loc(
                            "连接成功，但返回的不是预期的 JSON：\(String(cleaned.prefix(120)))"
                        ))
                    }
                    return
                }

                let resolved = ThirdPartyModelStore.cachedStructuredMode(for: config)
                    ?? config.structuredOutputMode
                await MainActor.run {
                    testState = .success(String.loc(
                        "连接正常。结构化输出档位：\(resolved.displayName)，本次消耗 \(completion.inputTokens + completion.outputTokens) tokens。"
                    ))
                }
            } catch {
                await MainActor.run {
                    testState = .failure(error.localizedDescription)
                }
            }
        }
    }
}
