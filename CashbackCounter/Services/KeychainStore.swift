//
//  KeychainStore.swift
//  CashbackCounter
//
//  会话凭据的存储。
//
//  为什么不用 UserDefaults：UserDefaults 就是沙盒里一个明文 plist。
//  设备越狱、iTunes/Finder 的非加密备份、甚至某些取证工具都能直接读到它。
//  会话 token 是「能读取用户所有银行交易的钥匙」，和用户偏好设置不是一个量级的东西。
//
//  Keychain 的内容由系统加密，且这里用 kSecAttrAccessibleAfterFirstUnlock：
//  设备重启后至少解锁过一次才可读 —— 既保证后台任务（静默推送同步）能用，
//  又不至于像 kSecAttrAccessibleAlways 那样在锁屏状态下也敞开。
//

import Foundation
import Security

enum KeychainStore {

    enum Key: String {
        /// 后端签发的会话 JWT
        case sessionToken = "backend_session_token"
        /// 会话对应的 Apple user id（sub）。用来在启动时调 getCredentialState 检查授权是否被撤销
        case appleUserID = "apple_user_id"
    }

    /// 所有条目共用的 service 名，避免和别的 App / 别的用途撞车
    private static let service = "com.junhaohuang.CashbackCounter.auth"

    // MARK: - 读写

    static func save(_ value: String, for key: Key) {
        guard let data = value.data(using: .utf8) else { return }

        // Keychain 的 add 不会覆盖已存在的条目（返回 errSecDuplicateItem），
        // 所以先删再加是这里最省事也最不容易出错的写法。
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ Keychain 写入失败 (\(key.rawValue))，OSStatus=\(status)")
        }
    }

    static func read(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 退出登录 / 删除账号时清空所有认证相关条目
    static func clearAll() {
        delete(.sessionToken)
        delete(.appleUserID)
    }
}
