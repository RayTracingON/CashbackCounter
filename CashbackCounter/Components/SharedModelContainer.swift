//
//  SharedModelContainer.swift
//  CashbackCounter
//
//  全局唯一的 ModelContainer：主 App 与 App Intents（快捷指令）共用。
//
//  背景：之前两个 Intent 各自创建独立容器，且未指定 cloudKitDatabase（默认 .automatic），
//  快捷指令后台拉起 App 时会额外启动一套 CloudKit 同步栈，触发
//  "Error updating background task request: BGSystemTaskSchedulerErrorDomain Code=3" 日志；
//  同时主界面的 @Query 感知不到另一个容器的写入，记账后列表不能即时刷新。
//

import Foundation
import SwiftData

enum SharedModelContainer {

    static let shared: ModelContainer = makeContainer()

    private static func makeContainer() -> ModelContainer {
        let schema = Schema([
            Transaction.self, CreditCard.self, Income.self, Point.self, PointAdjustment.self,
            LinkedBankAccount.self
        ])
        let isSyncEnabled = UserDefaults.standard.object(forKey: "iCloudSyncEnabled") as? Bool ?? true

        #if targetEnvironment(simulator)
        // 在模拟器中，如果未登录 iCloud 或 CloudKit 容器未配置好，频繁的同步重试会导致控制台无限输出 Zone Not Found 错误，从而引发主线程严重卡顿。
        // 故在模拟器环境下默认不启用 CloudKit 同步，保证开发调试时的流畅度。
        let cloudKitDB: ModelConfiguration.CloudKitDatabase = .none
        let usesCloudKit = false
        #else
        let cloudKitDB: ModelConfiguration.CloudKitDatabase = isSyncEnabled ? .automatic : .none
        let usesCloudKit = isSyncEnabled
        #endif

        // 第一次尝试正常创建
        do {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: cloudKitDB)
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // ⚠️ 在删任何东西之前，先关掉 CloudKit 再试一次。
            //
            // 这一步是用一次真实的数据丢失换来的：给模型加了一个**没有 inverse 的关系**，
            // CloudKit 的 schema 校验直接拒绝整个 schema
            // （"CloudKit integration requires that all relationships have an inverse"）。
            // 这类错误和本地数据库里存了什么**毫无关系** —— 删库一百次也修不好它，
            // 但下面那段删库逻辑照删不误，于是用户的卡包和账单就没了。
            //
            // 先降级成本地模式：能开起来就说明数据库本身是好的，问题出在 CloudKit 约束上。
            // 代价是这次启动不同步 iCloud，但数据一条不少 —— 这个取舍不需要犹豫。
            // 用单独的 Bool 判断：CloudKitDatabase 不是 Equatable，没法直接和 .none 比
            if usesCloudKit {
                do {
                    let localOnly = ModelConfiguration(
                        schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
                    let container = try ModelContainer(for: schema, configurations: [localOnly])
                    print("""
                        ⚠️ CloudKit 配置下无法初始化，已降级为**仅本地**模式（数据完好，本次不同步 iCloud）。
                        错误: \(error)
                        这通常是 schema 不满足 CloudKit 约束：所有属性要有默认值、
                        所有关系要可空**且必须有 inverse**、不能用 @Attribute(.unique)。
                        """)
                    return container
                } catch {
                    print("⚠️ 仅本地模式也失败，说明数据库本身有问题: \(error)")
                }
            }

            // 走到这里才是真正的存储损坏 / 迁移失败，删库重建是唯一出路
            print("⚠️ ModelContainer 初始化失败，尝试删除本地数据库并重建... 错误: \(error)")

            // 删除本地 SwiftData 存储文件
            let defaultURL = URL.applicationSupportDirectory.appending(path: "default.store")
            let filesToDelete = [
                defaultURL,
                defaultURL.appendingPathExtension("shm"),
                defaultURL.appendingPathExtension("wal")
            ]
            for url in filesToDelete {
                try? FileManager.default.removeItem(at: url)
            }

            // 第二次尝试：使用全新的空数据库
            do {
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: cloudKitDB)
                let container = try ModelContainer(for: schema, configurations: [config])
                // 重建后 iCloud 重新同步可能产生重复数据，标记下次启动执行一次去重
                UserDefaults.standard.set(true, forKey: AppConfig.UserDefaultsKey.needsDataDeduplication)
                print("✅ 已成功重建本地数据库，iCloud 数据将自动重新同步。")
                return container
            } catch {
                // 最终兜底：使用内存模式，至少不崩溃
                print("❌ 重建数据库也失败了，回退到内存模式: \(error)")
                do {
                    let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                    return try ModelContainer(for: schema, configurations: [memConfig])
                } catch {
                    fatalError("无法创建任何 ModelContainer: \(error)")
                }
            }
        }
    }
}
