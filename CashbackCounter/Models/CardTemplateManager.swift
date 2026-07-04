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
            // 远端获取失败，从本地字符串常量读取 fallback
            guard let data = defaultCardTemplatesJSON.data(using: .utf8) else {
                throw NSError(domain: "CardTemplateManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "无法解析本地 fallback JSON"])
            }
            let decoder = JSONDecoder()
            rawTemplates = try decoder.decode([CardTemplate].self, from: data)
        }
        
        // 返回前排好序，避免在 View 的 body 中进行耗时的重排序操作
        return rawTemplates.sorted(by: {
            $0.bankName < $1.bankName || ($0.bankName == $1.bankName && $0.type < $1.type)
        })
    }
    
    /// 去重逻辑版本号：只有版本号变化（通常伴随 schema 变更发版）、或数据库被重建后，
    /// 才会重新执行一次全量去重。日常启动/切换 Tab 不再触发全表扫描。
    private static let deduplicationVersion = 1

    @MainActor
    func runDeduplicationIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        let lastVersion = defaults.integer(forKey: AppConfig.UserDefaultsKey.lastDeduplicationVersion)
        let needsDedup = defaults.bool(forKey: AppConfig.UserDefaultsKey.needsDataDeduplication)

        guard lastVersion < Self.deduplicationVersion || needsDedup else { return }

        // 1. 对信用卡去重，防止 CloudKit 同步或多次导入导致卡包重复卡片
        deduplicateCards(in: context)

        // 2. 对交易去重，防止 CloudKit 同步在 schema 迁移后产生重复交易记录
        deduplicateTransactions(in: context)

        defaults.set(Self.deduplicationVersion, forKey: AppConfig.UserDefaultsKey.lastDeduplicationVersion)
        defaults.set(false, forKey: AppConfig.UserDefaultsKey.needsDataDeduplication)
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
