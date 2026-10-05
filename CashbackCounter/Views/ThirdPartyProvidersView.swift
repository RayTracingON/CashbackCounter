//
//  ThirdPartyProvidersView.swift
//  CashbackCounter
//
//  第三方服务商列表：内置预设 + 用户添加的自定义服务商，选一个作为当前使用。
//

import SwiftUI

@available(iOS 27.0, *)
struct ThirdPartyProvidersView: View {

    /// 存储版本号：服务商增删改、切换当前、改密钥都会变，列表靠它刷新
    @AppStorage(ThirdPartyModelStore.revisionKey) private var storeRevision = 0

    var body: some View {
        // 读一下版本号，让 body 依赖它；真正的数据每次都从存储现取
        let _ = storeRevision
        let providers = ThirdPartyModelStore.providers
        let activeID = ThirdPartyModelStore.activeProviderID

        List {
            Section {
                ForEach(providers.filter { !$0.isCustom }) { provider in
                    row(provider, isActive: provider.id == activeID)
                }
            } header: {
                Text("内置服务商")
            }

            Section {
                ForEach(providers.filter(\.isCustom)) { provider in
                    row(provider, isActive: provider.id == activeID)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                ThirdPartyModelStore.delete(providerID: provider.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }

                NavigationLink {
                    ThirdPartyProviderEditorView(provider: .newCustom())
                } label: {
                    Label("添加自定义服务商", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("自定义服务商")
            } footer: {
                Text("兼容 OpenAI、Anthropic 或 Gemini 协议的任意服务都可以添加，比如自建中转、OpenRouter、硅基流动、Ollama。")
            }
        }
        .navigationTitle("第三方服务商")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            if activeID == nil {
                Label("还没有选择服务商，当前仍使用本地模型", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }

    private func row(_ provider: ModelProvider, isActive: Bool) -> some View {
        let ready = ThirdPartyModelStore.isReady(provider)
        return NavigationLink {
            ThirdPartyProviderEditorView(provider: provider)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: provider.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                    Text(status(of: provider, ready: ready))
                        .font(.caption)
                        .foregroundStyle(ready ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }

                Spacer()

                if isActive {
                    Text("使用中")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .swipeActions(edge: .leading) {
            if ready, !isActive {
                Button {
                    ThirdPartyModelStore.activeProviderID = provider.id
                } label: {
                    Label("使用", systemImage: "checkmark.circle")
                }
                .tint(.green)
            }
        }
    }

    private func status(of provider: ModelProvider, ready: Bool) -> String {
        if ready { return provider.config.modelName.trimmed }
        if provider.isCustom, provider.config.normalizedBaseURL == nil { return String.loc("未填写 API 地址") }
        if !provider.isComplete { return String.loc("未选择模型") }
        return String.loc("未填写 API 密钥")
    }
}

#if DEBUG
#Preview("第三方服务商") {
    if #available(iOS 27.0, *) {
        NavigationStack {
            ThirdPartyProvidersView()
        }
    }
}
#endif
