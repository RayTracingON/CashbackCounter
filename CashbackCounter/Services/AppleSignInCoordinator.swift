//
//  AppleSignInCoordinator.swift
//  CashbackCounter
//
//  Apple 授权的两条路径，共用同一套 nonce 生成与结果解析。
//
//    A. 登录页上的 SignInWithAppleButton —— 它自己管 controller，
//       我们只需要在它的 request / completion 回调里挂上 nonce 和解析逻辑
//    B. 401 之后的静默续期 —— 没有按钮可点，必须自己起一个 ASAuthorizationController
//
//  两条路径的 nonce 规则必须完全一致，所以生成和解析都做成 static，
//  谁也别想只改一边。
//

import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// 一次成功的 Apple 授权返回的东西
struct AppleCredential {
    /// Apple 签名的 JWT，后端用它确认身份。**只活 10 分钟**
    let identityToken: String
    /// 一次性授权码。后端用它换 refresh_token，唯一用途是将来注销账号时撤销授权
    let authorizationCode: String?
    /// Apple 的用户唯一标识，本 App 内恒定不变
    let userID: String
    /// ⚠️ 只有**首次授权本 App** 时才有值，之后永远是 nil
    let email: String?
    /// 同上，只有首次授权时有值
    let fullName: String?
    /// 生成 nonce 时的随机串原文，要连同 identityToken 一起发给后端比对
    let rawNonce: String
}

enum AppleSignInError: LocalizedError {
    case canceled
    case missingIdentityToken
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .canceled:
            return "已取消 Apple 登录"
        case .missingIdentityToken:
            return "Apple 未返回身份凭据，请重试"
        case .failed(let error):
            return "Apple 登录失败：\(error.localizedDescription)"
        }
    }
}

@MainActor
final class AppleSignInCoordinator: NSObject {

    private var continuation: CheckedContinuation<AppleCredential, Error>?
    private var pendingRawNonce: String = ""
    /// 授权过程中必须持有 controller，否则它会被提前释放、回调永远不来
    private var controller: ASAuthorizationController?

    // MARK: - 路径 A：配合 SignInWithAppleButton

    /// 在按钮的 request 回调里调用。返回随机串**原文**，调用方要留着，
    /// 授权成功后连同 identityToken 一起交给 `credential(from:rawNonce:)`。
    ///
    /// 放进请求的是原文的 SHA-256，原文本身不出设备。Apple 会把这个哈希
    /// 原样写进 identityToken 的 nonce 声明，后端拿原文重算比对 ——
    /// 截获了旧 token 的人造不出对应的原文，重放就失效了。
    @discardableResult
    static func prepare(_ request: ASAuthorizationAppleIDRequest) -> String {
        let raw = randomNonceString()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256Hex(raw)
        return raw
    }

    /// 在按钮的 completion 回调里调用，把系统返回的东西解析成我们要的形状。
    static func credential(from authorization: ASAuthorization,
                           rawNonce: String) throws -> AppleCredential {

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            throw AppleSignInError.missingIdentityToken
        }

        let authorizationCode = credential.authorizationCode
            .flatMap { String(data: $0, encoding: .utf8) }

        let fullName = credential.fullName.flatMap { components -> String? in
            let name = PersonNameComponentsFormatter().string(from: components)
            return name.isEmpty ? nil : name
        }

        return AppleCredential(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            userID: credential.user,
            email: credential.email,
            fullName: fullName,
            rawNonce: rawNonce)
    }

    /// 把系统回调里的 Error 归一成我们的错误类型。用户主动取消要能被单独识别出来 ——
    /// 那不是失败，不该弹错误提示。
    static func mapError(_ error: Error) -> AppleSignInError {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            return .canceled
        }
        return .failed(error)
    }

    // MARK: - 路径 B：无按钮的静默续期

    /// 自己起一次 Apple 授权，用于会话过期后的自动恢复。
    ///
    /// 对**已经授权过**本 App 的用户，系统通常只闪一下确认界面（或直接 Face ID）就返回，
    /// 这就是「静默续期」能成立的原因 —— 不需要跳回我们自己的登录页。
    /// 但要清楚它并非真的无感：Apple 没有提供纯后台刷新 identityToken 的接口。
    func authorize() async throws -> AppleCredential {
        // 防重入：上一次还没结束就再发起一次，continuation 会被覆盖，
        // 前一次永远不 resume（表现为整个调用链挂死）。
        guard continuation == nil else {
            throw AppleSignInError.canceled
        }

        let request = ASAuthorizationAppleIDProvider().createRequest()
        pendingRawNonce = Self.prepare(request)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    // MARK: - 授权状态

    /// 检查系统设置里是否还授权着本 App。
    /// 用户可以在「设置 → Apple 账户 → 使用 Apple ID 的 App」里随时撤销，
    /// 撤销后我们手里的会话 token 在语义上就该失效了。
    static func credentialState(for userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }

    // MARK: - nonce

    /// 密码学安全的随机串。用 SecRandomCopyBytes 而不是 Int.random ——
    /// 后者是给游戏和动画用的，不保证不可预测。
    static func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            guard status == errSecSuccess else {
                fatalError("无法生成安全随机数，OSStatus=\(status)")
            }
            // 只取落在字符集范围内的字节，避免取模引入的分布偏差
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    /// ⚠️ 必须是小写十六进制，和后端 `HexFormat.of().formatHex(...)` 的输出一致。
    /// 大小写不一致会表现为「nonce 不匹配」的 401，而且极难联想到根因。
    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        let nonce = pendingRawNonce
        let continuation = self.continuation
        finish()

        do {
            continuation?.resume(returning: try Self.credential(from: authorization, rawNonce: nonce))
        } catch {
            continuation?.resume(throwing: error)
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        let continuation = self.continuation
        finish()
        continuation?.resume(throwing: Self.mapError(error))
    }

    private func finish() {
        continuation = nil
        controller = nil
        pendingRawNonce = ""
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? ASPresentationAnchor()
    }
}
