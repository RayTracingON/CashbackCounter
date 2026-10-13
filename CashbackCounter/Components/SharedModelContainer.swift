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

    /// 本次启动是否把打不开的旧数据库挪到了旁边并重建。
    /// 挪走的文件一个都没删，位置记在 UserDefaults（见 `recoveryNotice`）。
    private(set) static var didRebuildStore = false

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
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: cloudKitDB)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // ⚠️ 在动任何文件之前，先关掉 CloudKit 再试一次。
            //
            // 这一步是用一次真实的数据丢失换来的：给模型加了一个**没有 inverse 的关系**，
            // CloudKit 的 schema 校验直接拒绝整个 schema
            // （"CloudKit integration requires that all relationships have an inverse"）。
            // 这类错误和本地数据库里存了什么**毫无关系** —— 删库一百次也修不好它，
            // 但下面那段重建逻辑照跑不误，于是用户的卡包和账单就没了。
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

            // 走到这里才是真正的存储损坏 / 迁移失败。
            //
            // ⚠️ **只挪不删。** 之前这里直接 removeItem，而且用的还是错误的文件名
            // （`default.store.wal`，SQLite 实际写的是 `default.store-wal`）：主库被删、
            // 带着最新写入页的 WAL 却留在原地，谁也找不回来。
            // 现在把三个文件整体搬进带时间戳的备份目录，再在原位置重建一个空库。
            // 关了 iCloud 的用户至少还能从备份里救回数据；开了 iCloud 的会自动重新同步。
            print("⚠️ ModelContainer 初始化失败，把本地数据库挪到备份目录后重建... 错误: \(error)")

            if let backupDirectory = moveStoreAside(storeURL: config.url) {
                let defaults = UserDefaults.standard
                defaults.set(backupDirectory.path, forKey: AppConfig.UserDefaultsKey.storeBackupPath)
                defaults.set(Date(), forKey: AppConfig.UserDefaultsKey.storeBackupDate)
                didRebuildStore = true
            }

            // 第二次尝试：使用全新的空数据库
            do {
                let fresh = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: cloudKitDB)
                let container = try ModelContainer(for: schema, configurations: [fresh])
                // 重建后 iCloud 重新同步可能产生重复数据，标记下次启动执行一次去重
                UserDefaults.standard.set(true, forKey: AppConfig.UserDefaultsKey.needsDataDeduplication)
                print("✅ 已在原位置重建本地数据库，旧库保留在备份目录；iCloud 数据将自动重新同步。")
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

    // MARK: - 存储文件搬运

    /// SQLite 在 WAL 模式下的三个文件：主库、`-shm`、`-wal`。
    /// 边车文件名是在**完整文件名后面**接 `-shm` / `-wal`（`default.store-wal`），
    /// 不是换扩展名 —— `appendingPathExtension("wal")` 得到的 `default.store.wal` 根本不存在。
    static func storeFileURLs(for storeURL: URL) -> [URL] {
        [storeURL,
         URL(fileURLWithPath: storeURL.path + "-shm"),
         URL(fileURLWithPath: storeURL.path + "-wal")]
    }

    /// 备份目录统一放在存储文件旁边的 `StoreBackups/` 下，按时间戳分目录。
    static func backupRootDirectory(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: "StoreBackups", directoryHint: .isDirectory)
    }

    /// 把数据库连同边车文件搬进一个新的时间戳目录，返回该目录；一个文件都没搬动时返回 nil。
    ///
    /// 只搬 SQLite 文件本身。`.externalStorage` 的图片 blob 在旁边的 `default_SUPPORT/` 里，
    /// 留在原地：新库不会引用它们（顶多占点空间），而备份库恢复回来时还能找到它们。
    @discardableResult
    static func moveStoreAside(storeURL: URL, now: Date = Date()) -> URL? {
        let fileManager = FileManager.default
        let existing = storeFileURLs(for: storeURL).filter { fileManager.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = backupRootDirectory(for: storeURL)
            .appending(path: "default.store.corrupt-\(formatter.string(from: now))", directoryHint: .isDirectory)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("❌ 无法创建备份目录 \(directory.path): \(error)")
            return nil
        }

        var moved = 0
        for url in existing {
            let target = directory.appending(path: url.lastPathComponent)
            do {
                try fileManager.moveItem(at: url, to: target)
                moved += 1
            } catch {
                // 搬不动就原地不动。宁可重建失败回退到内存模式，也不能把它删了。
                print("❌ 无法移动 \(url.lastPathComponent) 到备份目录: \(error)")
            }
        }
        return moved > 0 ? directory : nil
    }

    // MARK: - 给界面用的提示

    struct RecoveryNotice {
        let backupPath: String
        let date: Date
    }

    /// 上一次（或本次）启动挪走了打不开的数据库时，这里有值；界面提示过一次后调 `clearRecoveryNotice()`。
    static var recoveryNotice: RecoveryNotice? {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: AppConfig.UserDefaultsKey.storeBackupPath) else { return nil }
        let date = defaults.object(forKey: AppConfig.UserDefaultsKey.storeBackupDate) as? Date ?? Date()
        return RecoveryNotice(backupPath: path, date: date)
    }

    static func clearRecoveryNotice() {
        UserDefaults.standard.removeObject(forKey: AppConfig.UserDefaultsKey.storeBackupPath)
        UserDefaults.standard.removeObject(forKey: AppConfig.UserDefaultsKey.storeBackupDate)
    }
}
