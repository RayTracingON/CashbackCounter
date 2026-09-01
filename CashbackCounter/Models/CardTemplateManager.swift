//
//  CardTemplateManager.swift
//  CashbackCounter
//

import Foundation
import SwiftData

@Observable
final class CardTemplateManager {
    static let shared = CardTemplateManager()
    
    // 替换为你的 GitHub Raw 链接
    let remoteURL = AppConfig.cardTemplatesURL
    
    var templates: [CardTemplate] = []
    
    private var hasSyncedThisLaunch = false
    private var hasRefreshedThisLaunch = false
    
    private init() {}
    
    @MainActor
    func syncTemplates(force: Bool = false) async {
        if hasSyncedThisLaunch && !force { return }
        do {
            let seeds = try await fetchTemplateSeeds()
            self.templates = seeds
            self.hasSyncedThisLaunch = true
        } catch {
            print("❌ Failed to sync templates: \(AppError.networkFailure(underlying: error).localizedDescription)")
        }
    }
    
    private func fetchTemplateSeeds() async throws -> [CardTemplate] {
        let rawTemplates: [CardTemplate]
        // 尝试从远端获取
        do {
            var request = URLRequest(url: remoteURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = AppConfig.networkTimeout
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                let decoder = JSONDecoder()
                rawTemplates = try decoder.decode([CardTemplate].self, from: data)
            } else {
                throw NSError(domain: "CardTemplateManager", code: 404)
            }
        } catch {
            print("⚠️ 无法从远端获取配置，尝试读取本地缓存... (\(error.localizedDescription))")
            // 远端获取失败，读取打包在 App 内的 CardTemplates.json 作为 fallback
            guard let url = Bundle.main.url(forResource: "CardTemplates", withExtension: "json") else {
                throw NSError(domain: "CardTemplateManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "Bundle 中未找到 CardTemplates.json"])
            }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            rawTemplates = try decoder.decode([CardTemplate].self, from: data)
        }
        
        // 返回前排好序，避免在 View 的 body 中进行耗时的重排序操作
        return rawTemplates.sorted(by: {
            $0.bankName < $1.bankName || ($0.bankName == $1.bankName && $0.type < $1.type)
        })
    }
    
    /// 去重逻辑版本号：手动 +1 可强制所有用户在下次启动全量去重一次
    /// （用于去重规则本身改动后的一次性重扫）。
    ///
    /// v2：交易去重从"内容指纹"改成 `Transaction.dedupeID`。这一版必须跑，
    /// 因为旧数据的 dedupeID 是空的，要靠这次全量扫描补齐 —— 补齐之前
    /// 它们不受任何保护。
    private static let deduplicationVersion = 2

    /// 当前 App 构建号（CFBundleVersion）。每次发版都会变 —— 用它判断「是不是刚更新过」，
    /// 因为 CloudKit 正是在 App 更新触发 schema 迁移后重新导入、制造重复数据的。
    private static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    @MainActor
    func runDeduplicationIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard

        // ── 卡片去重：每次启动都跑 ──
        // 卡片数量很少（几十张），全表扫描代价可忽略；而 CloudKit 的重新导入是**异步**的，
        // 重复卡片可能在本次去重跑完之后才同步下来。每次启动都清一遍，保证
        // 「重复出现后最迟下次启动就被合并」，这正是修复用户反馈的卡片翻倍问题的关键。
        deduplicateCards(in: context)

        // ── 交易去重：较重（可能上千条），只在必要时跑 ──
        // 触发条件（任一满足）：去重规则版本号提升 / App 刚更新过（构建号变化）/ 数据库被重建。
        // 「构建号变化」覆盖了每次发版后 CloudKit 重新导入产生重复交易的场景。
        let lastVersion = defaults.integer(forKey: AppConfig.UserDefaultsKey.lastDeduplicationVersion)
        let lastBuild = defaults.string(forKey: AppConfig.UserDefaultsKey.lastDeduplicationBuild)
        let needsDedup = defaults.bool(forKey: AppConfig.UserDefaultsKey.needsDataDeduplication)
        let buildChanged = lastBuild != Self.currentBuild

        if lastVersion < Self.deduplicationVersion || buildChanged || needsDedup {
            deduplicateTransactions(in: context)
            defaults.set(Self.deduplicationVersion, forKey: AppConfig.UserDefaultsKey.lastDeduplicationVersion)
            defaults.set(Self.currentBuild, forKey: AppConfig.UserDefaultsKey.lastDeduplicationBuild)
            defaults.set(false, forKey: AppConfig.UserDefaultsKey.needsDataDeduplication)
        }
    }

    @MainActor
    func refreshCardsFromTemplates(in context: ModelContext, force: Bool = false) throws {
        if hasRefreshedThisLaunch && !force { return }

        runDeduplicationIfNeeded(in: context)
        
        let templateMap = Dictionary(self.templates.map { ($0.templateKey, $0) }, uniquingKeysWith: { first, _ in first })
        if templateMap.isEmpty { return }
        
        let pointDescriptor = FetchDescriptor<Point>()
        let currentPoints = try context.fetch(pointDescriptor)
        let pointMap = Dictionary(currentPoints.map {
            (CardTemplate.pointTemplateKey(bankName: $0.bankName, pointName: $0.pointName, currencyCode: $0.valueCurrencyCode), $0)
        }, uniquingKeysWith: { first, _ in first })

        let cards = try context.fetch(FetchDescriptor<CreditCard>())
        var hasChanges = false
        for card in cards {
            guard let key = card.templateKey, let template = templateMap[key] else { continue }
            let modified = template.applyRules(to: card, pointMap: pointMap)
            if modified {
                hasChanges = true
            }
        }
        
        if hasChanges {
            try context.save()
            print("✅ Card templates refreshed and saved to DB.")
        }
        hasRefreshedThisLaunch = true
    }
    
    /// 自动合并重复信用卡，并将关联交易重定向到保留的 master 卡片上，避免用户界面卡包重复
    @MainActor
    func deduplicateCards(in context: ModelContext) {
        do {
            let cards = try context.fetch(FetchDescriptor<CreditCard>())
            guard cards.count > 1 else { return }
            
            // 按银行名、卡种名称和尾号进行分组（忽略首尾空格和大小写）
            var grouped: [String: [CreditCard]] = [:]
            for card in cards {
                // 防御：跳过 CloudKit 同步中尚未完全填充的「幽灵记录」
                let bank = card.bankName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let type = card.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !bank.isEmpty, !type.isEmpty else { continue }
                let endNum = card.endNum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                // 尾号为空时无法可靠判定是否为同一张卡；因本方法现在每次启动都跑，
                // 不加此保护会把两张同行同卡种、都没填尾号的**不同**卡片误并，造成数据丢失。
                guard !endNum.isEmpty else { continue }
                let key = "\(bank)|\(type)|\(endNum)"
                grouped[key, default: []].append(card)
            }
            
            var hasDeletes = false
            
            for (key, cardGroup) in grouped where cardGroup.count > 1 {
                print("🔍 Found duplicates for card: \(key) (count: \(cardGroup.count))")
                
                // 优先保留包含交易记录最多、或已下载卡面图数据的卡片作为 master
                let sortedGroup = cardGroup.sorted { c1, c2 in
                    let count1 = c1.transactions?.count ?? 0
                    let count2 = c2.transactions?.count ?? 0
                    if count1 != count2 {
                        return count1 > count2
                    }
                    let hasImg1 = c1.cardImageData != nil ? 1 : 0
                    let hasImg2 = c2.cardImageData != nil ? 1 : 0
                    return hasImg1 > hasImg2
                }
                
                let masterCard = sortedGroup[0]
                let duplicatesToDelete = sortedGroup.dropFirst()
                
                for duplicateCard in duplicatesToDelete {
                    // 在删除前，必须将关联的交易记录全部转移给 master 卡片，防交易丢失
                    if let txs = duplicateCard.transactions, !txs.isEmpty {
                        for tx in txs {
                            tx.card = masterCard
                        }
                        print("🔀 Transferred \(txs.count) transactions from duplicate card to master card")
                    }

                    // ⚠️ 银行绑定同样必须转移，而且理由比交易更隐蔽。
                    //
                    // CreditCard.linkedBankAccounts 是 .nullify：删掉副本卡只会把
                    // LinkedBankAccount.card 置空，记录本身留着。而 isSyncable 要求
                    // `syncEnabled && card != nil` —— 于是这张卡从此**静默停止同步**，
                    // 银行同步页只把它显示成"未关联"，没有任何报错。
                    // 而这个函数每次启动都跑，用户完全无从察觉。
                    if let accounts = duplicateCard.linkedBankAccounts, !accounts.isEmpty {
                        let masterAccountIds = Set((masterCard.linkedBankAccounts ?? []).map(\.accountId))
                        for account in accounts {
                            if masterAccountIds.contains(account.accountId) {
                                // master 已经绑着同一个 Plaid 账户，这条是纯冗余指针。
                                // 留着会在银行同步页显示成一条永远"未关联"的僵尸记录。
                                context.delete(account)
                            } else {
                                account.card = masterCard
                            }
                        }
                        print("🔀 Transferred \(accounts.count) linked bank accounts to master card")
                    }

                    // 卡面图：master 没有就从副本接过来，别把已下载的图跟着副本一起删掉
                    if masterCard.cardImageData == nil, let image = duplicateCard.cardImageData {
                        masterCard.cardImageData = image
                    }

                    context.delete(duplicateCard)
                    hasDeletes = true
                }
            }
            
            if hasDeletes {
                try context.save()
                print("✅ Successfully deduplicated duplicate cards.")
            }
        } catch {
            print("❌ Failed to deduplicate cards: \(AppError.saveFailed(underlying: error).localizedDescription)")
        }
    }
    
    /// 自动合并 CloudKit 在 schema 迁移后重新导入产生的重复交易。
    ///
    /// ⚠️ **只按 `Transaction.dedupeID` 分组，绝不按内容分组。**
    ///
    /// 这里曾经用 (商户, 日期, 金额, 入账金额, 卡) 当指纹，那是错的：同一天在同一家店
    /// 买两杯一样的咖啡，就是两笔内容完全相同的**真实**交易，按内容去重会把第二杯
    /// 永久删掉 —— 而且这个函数每次 App 更新后都会跑一遍，用户根本不会发现自己的账
    /// 每次升级都少一笔。同步引擎早就为同一个问题绕过路（见
    /// `PlaidSyncService.insertWithCountAlignment` 的"为什么不能用存在即跳过"），
    /// 本地去重不能再踩回去。
    ///
    /// dedupeID 由 `Transaction.init` 生成一次。CloudKit 复制记录时会把它一起复制，
    /// 所以真正的重复共享同一个值；两杯咖啡是两个不同的 UUID。
    ///
    /// 旧数据（该字段出现之前建的账）dedupeID 为空，这里就地补一个新 UUID。
    /// 代价是**此刻已经存在的重复合并不掉** —— 每个副本会拿到各自的 UUID。
    /// 这个取舍不需要犹豫：多一笔用户看得见也能自己删，凭空少一笔看不见也救不回来。
    /// 补完之后再发生的 CloudKit 重新导入都能被正确识别。
    @MainActor
    func deduplicateTransactions(in context: ModelContext) {
        do {
            let transactions = try context.fetch(FetchDescriptor<Transaction>())
            guard transactions.count > 1 else { return }

            // 第一步：按 dedupeID 分组；顺手给旧数据补标识。
            // 刚补上的 UUID 天然唯一，只会形成单元素分组，不参与任何删除。
            var grouped: [String: [Transaction]] = [:]
            var backfilled = 0
            for tx in transactions {
                if tx.dedupeID.isEmpty {
                    tx.dedupeID = UUID().uuidString
                    backfilled += 1
                    continue
                }
                grouped[tx.dedupeID, default: []].append(tx)
            }

            var deleteCount = 0

            for (_, txGroup) in grouped where txGroup.count > 1 {
                // 优先保留有收据图片或有收入记录的交易作为 master
                let sortedGroup = txGroup.sorted { t1, t2 in
                    // 优先保留有 receiptData 的
                    let hasReceipt1 = t1.receiptData != nil ? 1 : 0
                    let hasReceipt2 = t2.receiptData != nil ? 1 : 0
                    if hasReceipt1 != hasReceipt2 {
                        return hasReceipt1 > hasReceipt2
                    }
                    // 优先保留有收入记录的
                    let incomeCount1 = t1.incomes?.count ?? 0
                    let incomeCount2 = t2.incomes?.count ?? 0
                    return incomeCount1 > incomeCount2
                }

                let masterTx = sortedGroup[0]
                let duplicatesToDelete = sortedGroup.dropFirst()

                for dupTx in duplicatesToDelete {
                    // 转移收据数据（如果 master 没有但 duplicate 有）
                    if masterTx.receiptData == nil, let receiptData = dupTx.receiptData {
                        masterTx.receiptData = receiptData
                    }

                    // 转移收入记录到 master 交易
                    if let incomes = dupTx.incomes, !incomes.isEmpty {
                        for income in incomes {
                            income.transaction = masterTx
                        }
                    }

                    context.delete(dupTx)
                    deleteCount += 1
                }
            }

            if deleteCount > 0 || backfilled > 0 {
                try context.save()
                print("✅ 交易去重完成：删除 \(deleteCount) 条重复、补齐 \(backfilled) 条旧数据标识")
            }
        } catch {
            print("❌ 交易去重失败: \(AppError.saveFailed(underlying: error).localizedDescription)")
        }
    }
    
}
