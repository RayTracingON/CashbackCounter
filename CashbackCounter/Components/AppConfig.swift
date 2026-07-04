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
