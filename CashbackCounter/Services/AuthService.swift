//
//  AuthService.swift
//  CashbackCounter
//
//  登录状态的唯一出口。全 App 判断「登录了没」只看这里的 isSignedIn。
//
//  设计取舍：**登录不是使用 App 的前提**。
//  手动记账、卡包、费率引擎这些功能一行网络请求都不需要，强制登录只会
//  把老用户挡在门外，也不符合 App Store 审核指南 5.1.1(i)（不得为
//  与账号无关的功能强制注册）。登录只在进入「银行同步」时才要求。
//

import AuthenticationServices
import Foundation
import Observation

@MainActor
@Observable
final class AuthService: PlaidAPISessionDelegate {

    static let shared = AuthService()

    // MARK: - 对外状态

    private(set) var isSignedIn: Bool = false
    /// 后端认的 userId，也就是 Apple 的 sub
    private(set) var userID: String?
    /// 正在走登录 / 注销流程，UI 拿它禁用按钮
    private(set) var isBusy: Bool = false

    // MARK: - 私有

    private let coordinator = AppleSignInCoordinator()
    private let api = PlaidAPIClient.shared

    /// 内存里的一份缓存，避免每个请求都读一次 Keychain（读 Keychain 是系统调用，不便宜）
    private var cachedToken: String?

    private init() {
        self.cachedToken = KeychainStore.read(.sessionToken)
        self.userID = KeychainStore.read(.appleUserID)
        self.isSignedIn = cachedToken != nil && userID != nil
        api.sessionDelegate = self
    }

    // MARK: - 登录

    /// 登录页上的 SignInWithAppleButton 走这条：系统已经把授权做完了，
    /// 这里只负责把结果换成我们自己的会话 token。
    func completeSignIn(with authorization: ASAuthorization, rawNonce: String) async throws {
        isBusy = true
        defer { isBusy = false }

        let credential = try AppleSignInCoordinator.credential(from: authorization, rawNonce: rawNonce)
        try await exchange(credential)
    }

    /// 没有按钮可点时（401 静默续期）走这条：自己起一次 Apple 授权。
    @discardableResult
    func signIn() async throws -> Bool {
        isBusy = true
        defer { isBusy = false }

        let credential = try await coordinator.authorize()
        try await exchange(credential)
        return true
    }

    /// 把 Apple 的一次性凭据换成我们自己的会话 token。
    private func exchange(_ credential: AppleCredential) async throws {
        let request = AppleLoginRequest(
            identityToken: credential.identityToken,
            rawNonce: credential.rawNonce,
            authorizationCode: credential.authorizationCode,
            email: credential.email,
            fullName: credential.fullName)

        let result: AppleLoginResponse = try await api.postUnauthenticated(
            "/api/auth/apple", body: request)

        // 顺序有讲究：先写 Keychain 再改内存状态。
        // 反过来的话，万一写 Keychain 失败，App 会以为自己登录了，
        // 下次冷启动却又变回未登录 —— 一个很难查的间歇性问题。
        KeychainStore.save(result.sessionToken, for: .sessionToken)
        KeychainStore.save(credential.userID, for: .appleUserID)

        cachedToken = result.sessionToken
        userID = credential.userID
        isSignedIn = true

        // 令牌可能在登录之前就从 APNs 到了，那时上报会因为没有会话而失败。
        // 登录成功是重试的最佳时机。
        await PushNotificationService.shared.uploadIfNeeded()

        // 订阅同理：用户可能先订阅再登录（付费墙不要求先登录），
        // 那次上报会因为没有会话而失败，登录后必须补一次，
        // 否则后端永远不知道这个人已经付过钱了。
        await SubscriptionManager.shared.refreshEntitlements()
        // 反向也要拉一次：订阅可能是后端侧开通的（兑换码、手工开通），
        // 本地 StoreKit 一无所知
        await SubscriptionManager.shared.refreshBackendStatus()
    }

    // MARK: - 退出与注销

    /// 退出登录：只清本地。
    ///
    /// 服务端那枚 token 在到期前技术上仍然有效（无状态 JWT 不可主动吊销），
    /// 但它已经不在任何设备上了。要即时吊销就得引入服务端会话表，
    /// 对这个量级的 App 不值得。
    func signOut() {
        KeychainStore.clearAll()
        cachedToken = nil
        userID = nil
        isSignedIn = false
        // 清掉"已上报"的记忆：下次登录（可能是另一个账号）要重新上报，
        // 否则新账号的设备令牌永远注册不上，推送会发到旧账号名下。
        PushNotificationService.shared.reset()
    }

    /// 注销账号。后端会先解绑所有银行、撤销 Apple 授权，再删用户记录。
    ///
    /// 任何一家银行解绑失败，后端会整体中止并返回错误 —— 这时**什么都没删**，
    /// 用户重试即可。这个「宁可不删也不半删」的取舍在后端 AuthService 里有详细说明。
    @discardableResult
    func deleteAccount() async throws -> AccountDeletionResponse {
        isBusy = true
        defer { isBusy = false }

        let result: AccountDeletionResponse = try await api.delete("/api/auth/account")
        signOut()
        return result
    }

    // MARK: - 启动时的状态核对

    /// 用户可能在「设置 → Apple ID → 使用 Apple ID 的 App」里撤销了授权，
    /// 或者干脆换了台设备。启动和回前台时核对一次，撤销了就本地登出。
    func refreshCredentialState() async {
        guard let userID else { return }

        let state = await AppleSignInCoordinator.credentialState(for: userID)
        switch state {
        case .authorized:
            break
        case .revoked, .notFound:
            print("ℹ️ Apple 授权已被撤销或失效，本地登出")
            signOut()
        case .transferred:
            // App 的开发者账号发生了迁移，sub 会变，需要重新登录
            print("ℹ️ Apple 账号标识已迁移，需要重新登录")
            signOut()
        @unknown default:
            break
        }
    }

    // MARK: - PlaidAPISessionDelegate

    func currentSessionToken() -> String? {
        cachedToken
    }

    /// 收到 401 时的自救：重走一次 Apple 授权换新会话。
    ///
    /// 对已授权用户系统通常只闪一下确认就过了。失败就把本地状态清成未登录，
    /// UI 那边会自然地退回到需要登录的样子，而不是卡在一个「明明显示已登录、
    /// 但每个请求都失败」的状态里。
    func recoverFromUnauthorized() async -> Bool {
        guard isSignedIn else { return false }

        do {
            let credential = try await coordinator.authorize()
            try await exchange(credential)
            return true
        } catch {
            print("⚠️ 会话续期失败，需要重新登录：\(error.localizedDescription)")
            signOut()
            return false
        }
    }
}

// MARK: - 传输模型

/// 字段名是后端 @JsonProperty 定的下划线命名
private struct AppleLoginRequest: Encodable {
    let identityToken: String
    let rawNonce: String
    let authorizationCode: String?
    let email: String?
    let fullName: String?

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case rawNonce = "raw_nonce"
        case authorizationCode = "authorization_code"
        case email
        case fullName = "full_name"
    }
}

private struct AppleLoginResponse: Decodable {
    let sessionToken: String
    let expiresAt: String
    let userId: String
    let isNewUser: Bool
}

struct AccountDeletionResponse: Decodable {
    /// 注销过程中解绑掉的银行数量
    let unlinkedItems: Int
    /// 是否成功通知 Apple 撤销了授权。false 时用户可能还要去系统设置里手动移除
    let appleAuthorizationRevoked: Bool
}
