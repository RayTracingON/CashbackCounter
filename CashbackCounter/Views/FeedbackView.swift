//
//  FeedbackView.swift
//  CashbackCounter
//
//  设置 › 关于 › 意见反馈。提交到自建后端，开发者在 /feedback 管理页上看。
//
//  不要求登录：登录本身出了问题的用户也得有地方说。登录了就记在账号名下，
//  没登录就匿名 —— 两种情况页面上都说清楚，免得用户以为我们能回复一条匿名反馈。
//

import SwiftUI

struct FeedbackView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var auth = AuthService.shared

    @State private var category: FeedbackCategory = .suggestion
    @State private var message = ""
    @State private var contact = ""

    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false

    /// 随反馈一起发出去的诊断信息，页面上原样列出来：发了什么就给用户看什么
    private let diagnostics = SubmissionDiagnostics.current()

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedContact: String { contact.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSubmit: Bool { !trimmedMessage.isEmpty && !isSubmitting }

    private var messagePlaceholder: LocalizedStringKey {
        switch category {
        case .bug: return "遇到了什么问题？在哪一步出现的？"
        case .suggestion: return "希望增加或改进什么？"
        case .other: return "想对我们说点什么？"
        }
    }

    var body: some View {
        Group {
            if didSubmit {
                SubmissionConfirmation(title: "感谢你的反馈",
                                       message: "我们已经收到，会认真看每一条。") {
                    dismiss()
                }
            } else {
                form
            }
        }
        .navigationTitle("意见反馈")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !didSubmit {
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
        .onChange(of: message) { _, new in
            message = FeedbackLimits.clamp(new, to: FeedbackLimits.message)
        }
        .onChange(of: contact) { _, new in
            contact = FeedbackLimits.clamp(new, to: FeedbackLimits.contact)
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("类型", selection: $category) {
                    ForEach(FeedbackCategory.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                TextField(messagePlaceholder, text: $message, axis: .vertical)
                    .lineLimit(6...14)
            } header: {
                Text("反馈内容")
            } footer: {
                // 快写满时才出现，平时不占地方
                let used = message.unicodeScalars.count
                if used > FeedbackLimits.message - 200 {
                    Text(verbatim: "\(used)/\(FeedbackLimits.message)")
                }
            }

            Section {
                TextField("邮箱或其他联系方式", text: $contact)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("联系方式（选填）")
            } footer: {
                Text(auth.isSignedIn
                     ? "已登录，反馈会记在你的账号下。留下联系方式方便我们回复你。"
                     : "未登录时匿名提交。如果希望收到回复，请留下联系方式。")
            }

            Section {
                LabeledContent("App 版本", value: diagnostics.appVersion)
                LabeledContent("系统", value: diagnostics.osVersion)
                LabeledContent("设备", value: diagnostics.deviceModel)
            } header: {
                Text("随反馈附带")
            } footer: {
                Text("这些信息用于排查问题，不包含任何个人信息或账单数据。")
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
            try await FeedbackService.shared.submitFeedback(FeedbackSubmission(
                category: category,
                message: trimmedMessage,
                contact: trimmedContact.isEmpty ? nil : trimmedContact,
                diagnostics: diagnostics))
            withAnimation { didSubmit = true }
        } catch {
            errorMessage = FeedbackService.userMessage(for: error)
        }
    }
}

// MARK: - 提交成功

/// 提交成功后替换掉整张表单的确认页，新卡建议和意见反馈共用。
///
/// 刻意不用 alert：在 alert 按钮里调 dismiss() 会被正在收起的 alert 吞掉 ——
/// 模拟器上实测点了「好」页面原地不动，键盘还弹了回来。换成页面内的确认态之后，
/// 「完成」只是个普通按钮，dismiss 走的是正常路径。
struct SubmissionConfirmation: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let onDone: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } description: {
            Text(message)
        } actions: {
            Button("完成", action: onDone)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("意见反馈") {
    NavigationStack {
        FeedbackView()
    }
}

#Preview("提交成功") {
    SubmissionConfirmation(title: "感谢你的反馈", message: "我们已经收到，会认真看每一条。") {}
}
#endif
