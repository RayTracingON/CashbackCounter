//
//  CardRequestView.swift
//  CashbackCounter
//
//  卡包 ⋯ 菜单里的「建议收录新卡」：模板库里没有用户的卡时，让他把卡报上来。
//  提交到自建后端，开发者在 /feedback 管理页上看，收录后出现在「从模板添加」里。
//
//  要求登录（后端也是这么拦的）。未登录时登录按钮就嵌在表单顶上 ——
//  用户正在填一张表，登录完应该留在原地接着填，而不是被带去另一个页面。
//

import SwiftUI

struct CardRequestView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var auth = AuthService.shared

    @State private var bankName = ""
    @State private var cardName = ""
    /// nil = 用户没选（"不确定"）。很多银行在好几个地区都发卡，不能替用户猜
    @State private var region: Region?
    @State private var rewardInfo = ""

    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false

    private var trimmedBank: String { bankName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCard: String { cardName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedReward: String { rewardInfo.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSubmit: Bool {
        auth.isSignedIn && !trimmedBank.isEmpty && !trimmedCard.isEmpty && !isSubmitting
    }

    /// 填了东西就不让下滑手势直接把 sheet 关掉 —— 返现信息可能写了一大段
    private var hasDraft: Bool {
        !trimmedBank.isEmpty || !trimmedCard.isEmpty || region != nil || !trimmedReward.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if didSubmit {
                    SubmissionConfirmation(title: "已收到你的建议",
                                           message: "收录后会出现在「从模板添加」的列表里。") {
                        dismiss()
                    }
                } else {
                    form
                }
            }
            .navigationTitle("建议收录新卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 提交成功后只留确认页上的「完成」：这时再出现「取消」会让人以为还能撤回
                if !didSubmit {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Button("提交") {
                                Task { await submit() }
                            }
                            .disabled(!canSubmit)
                        }
                    }
                }
            }
            .interactiveDismissDisabled((hasDraft && !didSubmit) || isSubmitting)
            .onChange(of: bankName) { _, new in
                bankName = FeedbackLimits.clamp(new, to: FeedbackLimits.bankName)
            }
            .onChange(of: cardName) { _, new in
                cardName = FeedbackLimits.clamp(new, to: FeedbackLimits.cardName)
            }
            .onChange(of: rewardInfo) { _, new in
                rewardInfo = FeedbackLimits.clamp(new, to: FeedbackLimits.rewardInfo)
            }
        }
    }

    private var form: some View {
        Form {
            if !auth.isSignedIn {
                Section {
                    InlineSignInButton()
                } header: {
                    Text("需要登录")
                } footer: {
                    Text("提交新卡建议需要先登录，只用于识别提交者、防止重复和滥用。")
                }
            }

            Section {
                TextField("银行，如 Chase、招商银行", text: $bankName)
                TextField("卡片名称，如 Freedom Flex", text: $cardName)
            } header: {
                Text("卡片")
            } footer: {
                Text("在「从模板添加」里找不到你的卡？告诉我们是哪张，收录后就能直接从模板添加。")
            }

            Section {
                Picker("发卡地区", selection: $region) {
                    Text("不确定").tag(Region?.none)
                    ForEach(Region.allCases, id: \.self) { r in
                        // 地区名和 CardTemplateListView 一样用 verbatim：rawValue 不进本地化目录
                        Text(verbatim: "\(r.icon) \(r.rawValue)").tag(Region?.some(r))
                    }
                }

                TextField("返现或积分规则", text: $rewardInfo, axis: .vertical)
                    .lineLimit(4...10)
            } header: {
                Text("返现信息（选填）")
            } footer: {
                Text("例如：餐饮 5%、超市 3%、其他 1%，每月上限 500。附上官网或条款链接会更快收录。\n\n提交时会附带 App 版本、系统版本和设备型号，便于排查问题。")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await FeedbackService.shared.submitCardRequest(CardRequestSubmission(
                bankName: trimmedBank,
                cardName: trimmedCard,
                region: region?.rawValue,
                rewardInfo: trimmedReward.isEmpty ? nil : trimmedReward,
                diagnostics: .current()))
            withAnimation { didSubmit = true }
        } catch {
            errorMessage = FeedbackService.userMessage(for: error)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("建议收录新卡") {
    // AuthService.isSignedIn 是 private(set)，预览里伪造不了「已登录」，
    // 所以这里看到的是带登录按钮的未登录态
    CardRequestView()
}
#endif
