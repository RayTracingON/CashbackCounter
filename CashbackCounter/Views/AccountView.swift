//
//  AccountView.swift
//  CashbackCounter
//
//  登录页与设置页的账号区。
//
//  登录只为「银行同步」服务 —— 手动记账、卡包、费率引擎都不需要账号，
//  所以这里的文案要说清楚「登录能换来什么」，而不是摆一堵墙。
//

import AuthenticationServices
import SwiftUI

// MARK: - 登录页

/// 以 sheet 形式弹出的登录页。用户点「银行同步」而尚未登录时出现。
struct SignInView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var auth = AuthService.shared
    @State private var errorMessage: String?
    /// 本次授权请求的 nonce 原文，在 request 回调里生成、completion 回调里用掉
    @State private var rawNonce: String = ""

    /// 登录成功后的回调，调用方拿它继续原本要做的事（比如进入绑定流程）
    var onSignedIn: (() -> Void)?

    /// 显式写出来，不用编译器合成的那个 —— 上面有 private 的 @State 属性，
    /// 合成的 memberwise init 会跟着降级成 fileprivate，别的文件就用不了了。
    init(onSignedIn: (() -> Void)? = nil) {
        self.onSignedIn = onSignedIn
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "building.columns")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)

                VStack(spacing: 10) {
                    Text("连接你的银行")
                        .font(.title2.bold())

                    Text("登录后即可绑定美国银行账户，交易自动同步并按你设置的费率计算返现与积分。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(alignment: .leading, spacing: 12) {
                    privacyRow(icon: "lock.shield",
                               text: "我们拿不到你的卡号 —— Plaid 任何产品都不提供完整卡号")
                    privacyRow(icon: "externaldrive.badge.xmark",
                               text: "交易数据不在服务器留存，每次都是现拉现用")
                    privacyRow(icon: "hand.raised",
                               text: "随时可以解绑银行或删除账号")
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)

                Spacer()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                SignInWithAppleButton(.signIn) { request in
                    // nonce 的生成规则只有一份，在 AppleSignInCoordinator 里。
                    // 原文留在这个 View 上，授权回来后要用它比对。
                    rawNonce = AppleSignInCoordinator.prepare(request)
                } onCompletion: { result in
                    Task { await handle(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .padding(.horizontal, 32)
                .disabled(auth.isBusy)
                .opacity(auth.isBusy ? 0.5 : 1)

                if auth.isBusy {
                    ProgressView()
                }

                Text("我们只用 Apple ID 做身份识别，不获取你的通讯录或其他资料。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }
            .navigationTitle("银行同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func privacyRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 22)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) async {
        errorMessage = nil

        switch result {
        case .failure(let error):
            // 用户主动取消不是错误，不弹任何东西
            if case .canceled = AppleSignInCoordinator.mapError(error) { return }
            errorMessage = AppleSignInCoordinator.mapError(error).localizedDescription

        case .success(let authorization):
            do {
                try await auth.completeSignIn(with: authorization, rawNonce: rawNonce)
                onSignedIn?()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 设置页里的账号区

/// 直接嵌进 SettingsView 的 List 里的一个 Section。
struct AccountSection: View {

    /// 两个确认框是互斥的，用一个枚举驱动一个 confirmationDialog，
    /// 而不是各挂一个 —— 同一个节点上叠越多 presentation 修饰符，
    /// 越容易在某一个还没收干净时另一个就要present，撞出
    /// "attempt to present ... which is already presenting"。
    private enum Confirmation: Identifiable {
        case signOut
        case deleteAccount
        var id: Self { self }
    }

    /// 结果提示。带标题是因为它既可能是成功也可能是失败，
    /// 原来固定写"账号已删除"在失败时是错的。
    private struct Outcome: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @State private var auth = AuthService.shared

    @State private var showSignIn = false
    @State private var confirmation: Confirmation?
    @State private var outcome: Outcome?

    var body: some View {
        Section {
            // ⚠️ 所有 presentation 修饰符都挂在**这一行**上，不要挂到 Section 上。
            //
            // Section 不是一个真正的视图容器 —— 加在它上面的修饰符会被分发给
            // 它的每一个子视图，**包括 header 和 footer**。于是
            // `.sheet(isPresented: $showSignIn)` 会变成三份（1 行 + header + footer），
            // 同一个 Bool 一变 true，三份同时要 present，一份成功、两份被丢弃 ——
            // 正是日志里"1 个 already presenting + 2 条 Attempt to present"的来源。
            //
            // primaryRow 在登录/未登录两种状态下都存在，所以它是唯一稳定的宿主。
            primaryRow
                .sheet(isPresented: $showSignIn) {
                    SignInView()
                }
                .confirmationDialog(
                    confirmation == .deleteAccount ? "删除账号？" : "退出登录？",
                    isPresented: Binding(
                        get: { confirmation != nil },
                        set: { if !$0 { confirmation = nil } }),
                    titleVisibility: .visible,
                    presenting: confirmation
                ) { item in
                    switch item {
                    case .signOut:
                        Button("退出登录", role: .destructive) { auth.signOut() }
                    case .deleteAccount:
                        Button("删除账号", role: .destructive) {
                            Task { await deleteAccount() }
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: { item in
                    switch item {
                    case .signOut:
                        Text("本地的卡片和交易记录都会保留。已绑定的银行不会解绑，重新登录后可继续同步。")
                    case .deleteAccount:
                        // 这段警告必须写实：删除是不可逆的，而且会连带解绑所有银行。
                        Text("将解绑你名下所有银行账户，并永久删除服务器上的账号记录，此操作不可撤销。\n\n本地已有的卡片和交易记录会保留 —— 历史账目不该因为解绑而消失。")
                    }
                }
                .alert(item: $outcome) { outcome in
                    Alert(title: Text(outcome.title),
                          message: Text(outcome.message),
                          dismissButton: .cancel(Text("好")))
                }

            // 银行同步的入口常驻，不因未登录而隐藏 ——
            // 拦截做在页面里的动作上（点「绑定银行」才要求登录）。
            // 藏起来的功能等于不存在，用户不会去找。
            NavigationLink {
                BankSyncView()
            } label: {
                Label("银行同步", systemImage: "building.columns")
            }

            if auth.isSignedIn {
                Button {
                    confirmation = .signOut
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(auth.isBusy)

                Button(role: .destructive) {
                    confirmation = .deleteAccount
                } label: {
                    Label("删除账号", systemImage: "trash")
                }
                .disabled(auth.isBusy)
            }
        } header: {
            Text("账号")
        } footer: {
            Text(auth.isSignedIn
                 ? "登录用于银行同步。退出登录不会删除任何本地数据。"
                 : "手动记账无需登录。只有绑定银行、自动同步交易才需要账号。")
        }
    }

    /// 承载全部弹窗的那一行。登录与未登录状态下都存在，所以它是唯一稳定的宿主。
    @ViewBuilder
    private var primaryRow: some View {
        if auth.isSignedIn {
            HStack {
                Label("Apple ID", systemImage: "person.crop.circle.badge.checkmark")
                Spacer()
                Text("已登录")
                    .foregroundStyle(.secondary)
            }
        } else {
            Button {
                showSignIn = true
            } label: {
                Label("使用 Apple ID 登录", systemImage: "apple.logo")
            }
        }
    }

    private func deleteAccount() async {
        do {
            let result = try await auth.deleteAccount()

            var message = result.unlinkedItems > 0
                ? "已解绑 \(result.unlinkedItems) 家银行，账号记录已删除。"
                : "账号记录已删除。"

            if !result.appleAuthorizationRevoked {
                // 诚实地告诉用户还剩一步 —— 否则他们会在系统设置里
                // 看到本 App 还挂在那儿，以为没删干净。
                message += "\n\n未能自动移除 Apple ID 的授权记录，如需彻底清理，请到「设置 → Apple 账户 → 使用 Apple ID 的 App」中手动移除。"
            }

            outcome = Outcome(title: "账号已删除", message: message)

        } catch {
            // 失败时标题不能还写"账号已删除" —— 后端整体中止的情况下
            // 服务器上什么都没删，说反了会让用户以为数据没了。
            outcome = Outcome(title: "删除失败", message: error.localizedDescription)
        }
    }
}
