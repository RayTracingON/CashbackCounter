//
//  BiometricGate.swift
//  CashbackCounter
//
//  唤起 Plaid Link 之前的一道生物识别关卡。
//
//  为什么需要它：会话 token 在 Keychain 里活 30 天，也就是说一个已登录用户
//  走到「绑定银行」面前时，除了手机本身解锁之外**不会遇到任何认证挑战**。
//  而那个按钮后面是「连接一个真实的银行账户」—— 任何拿到解锁手机的人
//  （送修、家人、失窃后锁屏前的几分钟）都能直接绑一家银行进去。
//
//  这道关卡把「持有已解锁的设备」升级成「持有设备 + 本人生物特征」，
//  而且它是抗钓鱼的：生物特征不出设备，也没有任何可以被骗走的共享密钥。
//
//  不存储任何生物特征数据 —— 系统只回一个通过/不通过。
//

import Foundation
import LocalAuthentication

enum BiometricGate {

    enum Outcome {
        case success
        /// 用户主动取消。**不是错误**，不该弹任何提示
        case canceled
        /// 设备根本没法做这件事（没设密码、没录入生物识别）
        case unavailable(String)
        case failed(String)
    }

    /// 要求用户用 Face ID / Touch ID（不可用时回落到设备密码）确认身份。
    ///
    /// 用 `.deviceOwnerAuthentication` 而不是 `.deviceOwnerAuthenticationWithBiometrics`：
    /// 后者在用户没录入生物识别时会直接失败，把人硬挡在门外；
    /// 前者会自动回落到设备密码，仍然是一道真实的关卡，但不会制造无法通过的死路。
    static func authenticate(reason: String) async -> Outcome {
        // 每次都新建 context。复用的话，系统会在
        // touchIDAuthenticationAllowableReuseDuration 内直接返回上次的成功结果 ——
        // 那就等于这道关卡在一段时间内形同虚设。
        let context = LAContext()
        context.localizedCancelTitle = "取消"

        var canEvaluateError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &canEvaluateError) else {
            return .unavailable(describe(canEvaluateError))
        }

        let result: Result<Bool, Error> = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                } else {
                    continuation.resume(returning: .success(success))
                }
            }
        }

        switch result {
        case .success(let ok):
            return ok ? .success : .failed("身份验证未通过")

        case .failure(let error):
            guard let laError = error as? LAError else {
                return .failed(error.localizedDescription)
            }
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .canceled
            case .userFallback:
                // 用户点了"输入密码"但又没完成。当作取消，不弹错误
                return .canceled
            case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled:
                return .unavailable(describe(laError as NSError))
            default:
                return .failed(laError.localizedDescription)
            }
        }
    }

    /// 当前设备可用的验证方式，用于文案（"Face ID" / "Touch ID" / "设备密码"）
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)

        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "设备密码"
        }
    }

    private static func describe(_ error: NSError?) -> String {
        guard let code = (error as? LAError)?.code else {
            return "无法在这台设备上完成身份验证"
        }
        switch code {
        case .passcodeNotSet:
            // 没设密码的设备上绑定银行账户风险太高，这里要说清楚为什么被挡
            return "这台设备没有设置密码。绑定银行账户前请先在「设置 → 面容 ID 与密码」中设置设备密码。"
        case .biometryNotEnrolled:
            return "尚未录入 \(methodName)。请先在系统设置中录入，或为设备设置密码。"
        case .biometryNotAvailable:
            return "这台设备的生物识别不可用。请为设备设置密码后重试。"
        case .biometryLockout:
            return "\(methodName) 已被锁定，请用设备密码解锁一次后重试。"
        default:
            return "无法完成身份验证"
        }
    }
}
