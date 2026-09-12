//
//  AppLanguage.swift
//  CashbackCounter
//

import Foundation
import SwiftUI

/// App 内语言切换的取词入口。
///
/// **为什么不能直接用 `String(localized:)`**：
/// `.environment(\.locale, …)` 只影响 SwiftUI 用 `Text("字面量")` 渲染出来的文案。
/// `String(localized:)` 是 Foundation 的接口，它按 `Bundle.main` 的
/// `preferredLocalizations`（也就是**系统**为本 App 解析出的语言）取词，
/// 根本看不到 SwiftUI 的 environment。结果就是：设置里切成 English 之后，
/// 凡是先算成 `String` 再塞进 `Text` 的地方——筛选条、图表标题、
/// 枚举的 `displayName`、错误文案——统统留在中文。
///
/// 解法是把语言解析权收回来：自己找到对应的 `.lproj` bundle，从那里取词。
/// 字符串目录（`Localizable.xcstrings`）在编译期会拆成每种语言一份
/// `<lang>.lproj/Localizable.strings`，所以运行时能直接按语言定位。
///
/// 用 ``String/loc(_:)`` 代替 `String(localized:)` 即可，见其文档。
/// 标 `nonisolated`：工程默认 actor 隔离是 MainActor，而服务层会在后台线程取词
/// （网络错误文案、解析失败提示…），取词本身只读 UserDefaults + 一把锁保护的缓存，
/// 本来就不需要主线程。
nonisolated enum AppLanguage {
    /// `@AppStorage("userLanguage")` 用的同一个 key，"system" 表示跟随系统。
    static let storageKey = "userLanguage"

    /// 用户在设置里选的值，未选过就是 "system"。
    static var selection: String {
        UserDefaults.standard.string(forKey: storageKey) ?? "system"
    }

    /// 实际生效的语言代码。跟随系统时回落到系统为本 App 解析出的那一种。
    static var languageCode: String {
        let selection = selection
        guard selection != "system" else {
            return Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        }
        return selection
    }

    /// 数字、日期、货币格式化用的 locale。
    ///
    /// 不管跟不跟随系统，都得带着用户真实的地区设置（英国用户的 en_GB
    /// 日期是 31/12/2025）。直接用 `Locale(identifier: languageCode)` 会把
    /// 地区抹平成语言默认值：英国用户一选「English」，日期就变成美式，
    /// 没显式指定 currencyCode 的 NumberFormatter 连货币符号都推不出来，
    /// 只会印出占位符（en 给 "¤123.45"、zh-Hans 给 "XXX 123.45"）。
    /// 所以只换语言、把地区原样留下。
    static var locale: Locale {
        guard selection != "system" else { return .current }
        var components = Locale.Components(identifier: languageCode)
        // 用 languageComponents.region 而不是 components.region：两者格式化结果
        // 一样，但前者拼出的是常规的 "en_GB" / "zh-Hans_GB"，后者是
        // "en@rg=gbzzzz" 这种地区覆盖写法，会让按 identifier 解析的地方（SwiftUI
        // 找 .lproj、日志）更难懂。
        components.languageComponents.region = Locale.current.region
        return Locale(components: components)
    }

    /// 当前语言对应的 `.lproj` bundle，跟随系统时就是 `.main`。
    ///
    /// 解析结果带缓存：取词是每帧都会走的热路径，而 `Bundle(path:)` 要碰磁盘。
    static var bundle: Bundle {
        let selection = selection
        guard selection != "system" else { return .main }

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached, cached.key == selection { return cached.bundle }

        let resolved = resolveBundle(for: selection)
        cached = (selection, resolved)
        return resolved
    }

    // MARK: - Bundle 解析

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (key: String, bundle: Bundle)?

    private static func resolveBundle(for code: String) -> Bundle {
        // "zh-Hans" 这类标识在 bundle 里可能是 zh-Hans.lproj，也可能只有
        // zh.lproj（取决于工程配的 knownRegions），两种都试一遍。
        // 一个都找不到就退回 .main —— 语言没切成，但不至于整屏没文案。
        for candidate in [code, String(code.prefix(2))] {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .main
    }
}

extension String {
    /// 按 App 内语言设置取词，`String(localized:)` 的替代品。
    ///
    /// 用法完全一致，插值也照常写：
    /// ```swift
    /// FilterChip(title: .loc("全部种类"), …)
    /// let tip = String.loc("\(month)月峰值")
    /// ```
    ///
    /// **不要**再直接调 `String(localized:)`——它忽略设置里的语言选择，原因见 ``AppLanguage``。
    /// `nonisolated`：工程默认隔离是 MainActor，不标的话服务层在后台线程取词
    /// 会报 `call to main actor-isolated static method 'loc'`。取词只读 UserDefaults
    /// 和一把锁保护的缓存，本来就与线程无关。
    nonisolated static func loc(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }
}
