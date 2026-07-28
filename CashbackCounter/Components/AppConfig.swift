//
//  AppConfig.swift
//  CashbackCounter
//
//  集中管理应用配置常量 — 替代散落在各文件中的硬编码 URL 和配置值。
//

import Foundation
import CoreGraphics

enum AppConfig {

    // MARK: - 远程 API 地址

    /// 信用卡模板配置文件（GitHub Raw）
    static let cardTemplatesURL = URL(string: "https://raw.githubusercontent.com/RayTracingON/CashbackCounter/refs/heads/Master/CashbackCounter/CardTemplates.json")!

    /// 汇率 API 基础地址（fawazahmed0 开源汇率 API）
    static let currencyAPIBaseURL = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/"

    // MARK: - 自建后端（Plaid 银行同步）

    enum Backend {

        /// 线上后端（Azure App Service）。对应 Plaid **production** 环境和真实银行账户。
        static let productionBaseURL = URL(string: "https://ascidean-plaid-api-ckbtf4ebfghaf5e0.australiacentral-01.azurewebsites.net")!

        /// 本地后端。对应 Plaid **sandbox** 环境。
        ///
        /// ⚠️ 两个环境的 Plaid access_token 互不通用，测试数据和真实数据不会混，
        /// 但也意味着在本地绑过的银行到线上一个都不认。
        static let developmentBaseURL = URL(string: "http://localhost:8080")!

        /// 真机调试时覆盖本地地址用 —— 真机连不到 Mac 的 localhost。
        /// 在开发者页面里填 `http://你的Mac名.local:8080`（ATS 只豁免 .local，纯 IP 不行）。
        static let developmentOverrideKey = "debug_backend_base_url"

        /// 当前生效的后端地址。
        ///
        /// 用 DEBUG 编译条件而不是运行时开关：release 构建里根本不存在指向本地的分支，
        /// 不可能因为一个残留的偏好设置就让线上包去连一个连不上的地址。
        static var baseURL: URL {
            #if DEBUG
            if let override = UserDefaults.standard.string(forKey: developmentOverrideKey),
               let url = URL(string: override), !override.isEmpty {
                return url
            }
            return developmentBaseURL
            #else
            return productionBaseURL
            #endif
        }
    }

    // MARK: - 第三方链接（设置/关于页面）

    /// 项目 GitHub 仓库
    static let githubRepoURL = URL(string: "https://github.com/raytracingon/cashbackcounter")!
    /// Cardentify 项目链接
    static let cardentifyRepoURL = URL(string: "https://github.com/HarukaKinen/Cardentify")!
    /// 汇率 API 项目链接
    static let exchangeAPIRepoURL = URL(string: "https://github.com/fawazahmed0/exchange-api")!

    // MARK: - 网络配置

    /// 网络请求超时时间（秒）
    static let networkTimeout: TimeInterval = 5.0

    // MARK: - 图片配置

    /// 收据图片 JPEG 压缩质量 (0.0 ~ 1.0)
    static let receiptJPEGQuality: CGFloat = 0.5

    // MARK: - UserDefaults Keys

    enum UserDefaultsKey {
        static let cachedExchangeRates = "cached_exchange_rates"
        static let lastFetchDate = "last_fetch_date"
        static let lastRatesBase = "last_rates_base"
        /// 已完成还款提醒通知 identifier 迁移（旧版用 hashValue，重启后无法取消）
        static let didMigrateReminderIdentifiers = "did_migrate_reminder_identifiers_v1"
        /// 上次执行数据去重时的去重逻辑版本号
        static let lastDeduplicationVersion = "last_deduplication_version"
        /// 数据库被重建（schema 迁移失败）后置为 true，提示下次启动需要去重
        static let needsDataDeduplication = "needs_data_deduplication"
    }
}
