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
    private static let deduplicationVersion = 1

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
    
    /// 自动合并重复交易记录，防止 CloudKit 同步在 schema 迁移后产生的重复交易
    /// 按 (商户名, 日期, 金额, 入账金额, 关联卡片) 进行分组，保留第一条，删除后续重复记录
    @MainActor
    func deduplicateTransactions(in context: ModelContext) {
        do {
            let transactions = try context.fetch(FetchDescriptor<Transaction>())
            guard transactions.count > 1 else { return }
            
            // 按 (商户名, 日期(精确到天), 金额, 入账金额, 卡片标识) 分组
            var grouped: [String: [Transaction]] = [:]
            for tx in transactions {
                let merchant = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let dayString = Self.deduplicationDateFormatter.string(from: tx.date)
                let amount = String(format: "%.2f", tx.amount)
                let billing = String(format: "%.2f", tx.billingAmount)
                let cardKey: String
                if let card = tx.card {
                    cardKey = "\(card.bankName)|\(card.endNum)".lowercased()
                } else {
                    cardKey = "nocard"
                }
                let key = "\(merchant)|\(dayString)|\(amount)|\(billing)|\(cardKey)"
                grouped[key, default: []].append(tx)
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
            
            if deleteCount > 0 {
                try context.save()
                print("✅ 交易去重完成：删除了 \(deleteCount) 条重复交易记录")
            }
        } catch {
            print("❌ 交易去重失败: \(AppError.saveFailed(underlying: error).localizedDescription)")
        }
    }
    
    private static let deduplicationDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
