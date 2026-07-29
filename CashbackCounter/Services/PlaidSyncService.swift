//
//  PlaidSyncService.swift
//  CashbackCounter
//
//  银行交易同步引擎。阶段 3 的全部规则集中在这一个类里。
//
//  三条贯穿始终的原则：
//
//  1. **只碰 source == .plaid 的记录。** 去重、退款抵销、任何形式的删除，
//     都绝不作用于用户手动记的账。
//  2. **管线幂等。** 同一批数据跑两遍的结果必须和跑一遍一样，
//     否则重叠的时间窗、重复的手动刷新都会制造脏数据。
//  3. **宁可少算不要多算。** 分不清的情况一律走保守分支 ——
//     少一笔用户能看出来，凭空多一笔或悄悄删一笔用户发现不了。
//
//  费率引擎**零改动**：入库走现有的 Transaction.init(card:)，
//  返现、积分、上限全部由它自动算，这里一行都没碰。
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PlaidSyncService {

    static let shared = PlaidSyncService()

    // MARK: - 可调参数

    /// 首次全量最多回溯多久。实际能拿到多少取决于银行，多数只给 12–24 个月
    private let maxLookbackDays = 730

    /// 递归二分时的最小窗口。到这个粒度还被截断就只能接受截断了
    private let minWindowDays = 7

    /// 增量同步的最小回看天数
    private let minIncrementalDays = 14

    /// 增量同步在上次同步时间之外**多回看**的天数。
    /// 覆盖两件事：pending 转 posted 的延迟、银行晚几天才报的交易。
    /// 重叠部分由去重吸收，多拉不会产生重复。
    private let incrementalOverlapDays = 7

    /// 退款最多往前找多久的原交易
    private let refundMatchWindowDays = 90

    /// PRODUCT_NOT_READY 的重试次数与间隔
    private let productNotReadyRetries = 12
    private let productNotReadyInterval: Duration = .seconds(10)

    // MARK: - 对外状态（UI 绑定）

    private(set) var isSyncing = false
    private(set) var statusMessage: String?

    private let api = PlaidAPIClient.shared

    private init() {}

    // MARK: - 结果

    struct SyncSummary {
        var inserted = 0
        var refundsApplied = 0
        var refundsUnmatched = 0
        var skippedPending = 0
        var duplicatesSkipped = 0
        /// 忽略掉的流入（还款、转账、收入）
        var ignoredInflows = 0
        /// 忽略掉的非消费流出（银行账户上的还款、转账）
        var ignoredOutflows = 0

        static func + (lhs: SyncSummary, rhs: SyncSummary) -> SyncSummary {
            SyncSummary(inserted: lhs.inserted + rhs.inserted,
                        refundsApplied: lhs.refundsApplied + rhs.refundsApplied,
                        refundsUnmatched: lhs.refundsUnmatched + rhs.refundsUnmatched,
                        skippedPending: lhs.skippedPending + rhs.skippedPending,
                        duplicatesSkipped: lhs.duplicatesSkipped + rhs.duplicatesSkipped,
                        ignoredInflows: lhs.ignoredInflows + rhs.ignoredInflows,
                        ignoredOutflows: lhs.ignoredOutflows + rhs.ignoredOutflows)
        }
    }

    // MARK: - 入口

    /// 同步所有已绑定且可同步的银行。
    ///
    /// 单个 item 失败不影响其它 item —— 一家银行连接断了，
    /// 不该让另外两家也同步不了。失败的收集起来一起报。
    @discardableResult
    func syncAll(context: ModelContext) async -> (summary: SyncSummary, errors: [String]) {
        let accounts = (try? context.fetch(FetchDescriptor<LinkedBankAccount>())) ?? []
        let itemIds = Set(accounts.filter(\.isSyncable).map(\.itemId))

        guard !itemIds.isEmpty else {
            return (SyncSummary(), [])
        }

        var total = SyncSummary()
        var errors: [String] = []

        for itemId in itemIds {
            do {
                total = total + (try await sync(itemId: itemId, context: context))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return (total, errors)
    }

    /// 同步一个 item。内部自己判断该走首次全量还是增量。
    @discardableResult
    func sync(itemId: String, context: ModelContext) async throws -> SyncSummary {
        isSyncing = true
        defer {
            isSyncing = false
            statusMessage = nil
        }

        let accounts = syncableAccounts(itemId: itemId, context: context)
        guard !accounts.isEmpty else { return SyncSummary() }

        let needsInitial = accounts.contains { !$0.didInitialSync }

        let (start, end): (Date, Date)
        if needsInitial {
            statusMessage = "正在导入历史交易…"
            end = Date()
            start = Calendar.current.date(byAdding: .day, value: -maxLookbackDays, to: end)!
        } else {
            statusMessage = "正在同步…"
            end = Date()
            start = incrementalStart(for: accounts, end: end)
        }

        let transactions = try await fetchRange(itemId: itemId, start: start, end: end)
        PlaidSyncDebugLogger.dumpFetched(transactions, itemId: itemId)

        statusMessage = "正在处理 \(transactions.count) 笔交易…"

        // 积分估值可能要查汇率（网络），所以**每张卡只解析一次**、在进入管线之前做完。
        // 放进循环里会变成每笔交易一次网络往返。
        let pointValues = await resolvePointValues(for: accounts)

        let summary = process(transactions, accounts: accounts, pointValues: pointValues, context: context)

        let now = Date()
        for account in accounts {
            account.lastSyncedAt = now
            account.didInitialSync = true
        }
        try context.save()

        let text = "新增 \(summary.inserted)、退款抵销 \(summary.refundsApplied)（未匹配 \(summary.refundsUnmatched)）、"
            + "去重跳过 \(summary.duplicatesSkipped)、pending 丢弃 \(summary.skippedPending)、"
            + "非消费流出忽略 \(summary.ignoredOutflows)、流入忽略 \(summary.ignoredInflows)"
        PlaidSyncDebugLogger.summary(itemId: itemId, text: text)
        print("✅ 同步完成 item=\(itemId): \(text)")
        return summary
    }

    /// 首次绑定后立刻调用。
    ///
    /// 刚绑完 Plaid 还在向银行拉数据，这时 /transactions 会返回 PRODUCT_NOT_READY。
    /// **那不是错误，是正常的等待**，所以这里按固定间隔重试而不是直接失败。
    /// 阶段 6 接上 APNs 之后，这条路径会退化成兜底 ——
    /// 到时候优先等后端转发的 HISTORICAL_UPDATE 推送。
    @discardableResult
    func performInitialSyncWaitingForData(itemId: String, context: ModelContext) async throws -> SyncSummary {
        for attempt in 0...productNotReadyRetries {
            do {
                return try await sync(itemId: itemId, context: context)
            } catch let error as PlaidAPIError where error.isProductNotReady {
                guard attempt < productNotReadyRetries else { throw error }
                isSyncing = true
                statusMessage = "银行数据正在准备中…（\(attempt + 1)/\(productNotReadyRetries)）"
                try await Task.sleep(for: productNotReadyInterval)
            }
        }
        return SyncSummary()
    }

    // MARK: - 拉取

    /// 按区间拉取，**遇到截断就对半切**再各拉一次。
    ///
    /// 后端单次最多返回 X-Max-Transactions 笔（默认 500），超了就被悄悄截掉。
    /// 不处理截断的话，一个消费频繁的用户会丢掉大段历史，而且完全没有征兆 ——
    /// 表现只是"导入的交易好像少了点"。
    ///
    /// 递归二分而不是顺序往回翻窗口：空白时段一次请求就跳过了，
    /// 密集时段会自动切到足够细，两头都不浪费请求。
    private func fetchRange(itemId: String, start: Date, end: Date) async throws -> [PlaidTransactionDTO] {
        let (batch, truncated) = try await fetchWindow(itemId: itemId, start: start, end: end)

        guard truncated else { return batch }

        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        guard days > minWindowDays else {
            print("⚠️ 区间 \(Self.iso(start))~\(Self.iso(end)) 已切到 \(days) 天仍被截断，接受截断")
            return batch
        }

        let mid = Calendar.current.date(byAdding: .day, value: -days / 2, to: end)!
        let older = try await fetchRange(itemId: itemId, start: start, end: mid)
        let newer = try await fetchRange(
            itemId: itemId,
            start: Calendar.current.date(byAdding: .day, value: 1, to: mid)!,
            end: end)
        return older + newer
    }

    private func fetchWindow(itemId: String,
                             start: Date,
                             end: Date) async throws -> ([PlaidTransactionDTO], Bool) {

        let (batch, headers): ([PlaidTransactionDTO], [AnyHashable: Any]) =
            try await api.getWithHeaders("/api/plaid/transactions", query: [
                URLQueryItem(name: "itemId", value: itemId),
                URLQueryItem(name: "startDate", value: Self.iso(start)),
                URLQueryItem(name: "endDate", value: Self.iso(end))
            ])

        // 上限由服务端在响应头里明说。读不到就退回一个保守值 ——
        // 猜小了只是多切几次窗口，猜大了会静默丢数据。
        let cap = (headers["X-Max-Transactions"] as? String).flatMap(Int.init) ?? 500
        let truncated = batch.count >= cap
        PlaidSyncDebugLogger.windowFetched(
            itemId: itemId, start: start, end: end, count: batch.count, truncated: truncated)
        return (batch, truncated)
    }

    // MARK: - 处理管线

    /// 单批数据的完整处理。顺序不能改：
    ///
    ///   ① 只留开了同步的账户  ② 丢弃 pending  ③ 负数分流
    ///   ④ 正数去重入库        ⑤ 退款抵销
    ///
    /// ⑤ 必须在 ④ 之后：同一批里既有消费又有它的退款时，
    /// 先入库才能被随后的退款正确抵销掉。
    /// 每张积分卡的「一点积分值多少发卡币种」。只解析一次，避免每笔交易查一次汇率。
    private func resolvePointValues(
        for accounts: [LinkedBankAccount]
    ) async -> [PersistentIdentifier: Double] {

        var result: [PersistentIdentifier: Double] = [:]
        for account in accounts {
            guard let card = account.card, card.rewardType == .points else { continue }
            let id = card.persistentModelID
            guard result[id] == nil else { continue }
            result[id] = await card.pointValueInCardCurrency()
        }
        return result
    }

    private func process(_ transactions: [PlaidTransactionDTO],
                         accounts: [LinkedBankAccount],
                         pointValues: [PersistentIdentifier: Double],
                         context: ModelContext) -> SyncSummary {

        var summary = SyncSummary()

        // accountId → 本地卡片。没开同步的账户根本不在这张表里，
        // 于是它们的流水在第一步就被自然过滤掉了。
        var cardByAccount: [String: CreditCard] = [:]
        for account in accounts {
            if let card = account.card {
                cardByAccount[account.accountId] = card
            }
        }

        var purchases: [(dto: PlaidTransactionDTO, card: CreditCard)] = []
        var refunds: [(dto: PlaidTransactionDTO, card: CreditCard)] = []

        PlaidSyncDebugLogger.processingHeader(transactions.count)

        for dto in transactions {
            // ① 不属于要同步的账户
            guard let card = cardByAccount[dto.accountId] else {
                PlaidSyncDebugLogger.decision(dto, verdict: "跳过",
                                              detail: "账户未开启同步或未关联卡片（\(dto.accountMask ?? "?")）")
                continue
            }

            // ② pending 一律丢弃。它的金额还会变（餐厅小费、加油站预授权）、
            // 日期还会移，入库之后等 posted 版本再来，就变成两笔。
            if dto.pending {
                summary.skippedPending += 1
                PlaidSyncDebugLogger.decision(dto, verdict: "丢弃", detail: "pending，等入账后再同步")
                continue
            }

            guard dto.parsedDate != nil else {
                PlaidSyncDebugLogger.decision(dto, verdict: "跳过", detail: "日期无法解析")
                continue
            }

            // ③ 按符号分流
            if dto.isInflow {
                if PlaidCategoryMapping.isNonRefundInflow(primary: dto.category) {
                    // 还款、转账、收入 —— 和消费无关，直接忽略
                    summary.ignoredInflows += 1
                    PlaidSyncDebugLogger.decision(dto, verdict: "忽略",
                                                  detail: "资金流入但非退款")
                } else {
                    refunds.append((dto, card))
                    PlaidSyncDebugLogger.decision(dto, verdict: "退款", detail: "待抵销原交易")
                }
            } else if PlaidCategoryMapping.isNonPurchaseOutflow(
                primary: dto.category, detailed: dto.categoryDetailed) {
                // 银行账户上的还款和转账是**正数**。不挡的话，
                // 一笔信用卡还款会被当成消费入库、还算出凭空的返现，
                // 而它对应的真实消费已经从信用卡那边同步过一遍了。
                summary.ignoredOutflows += 1
                PlaidSyncDebugLogger.decision(dto, verdict: "忽略",
                                              detail: "还款/转账，非消费")
            } else {
                purchases.append((dto, card))
            }
        }

        // ④
        let insertResult = insertWithCountAlignment(purchases, pointValues: pointValues, context: context)
        summary.inserted = insertResult.inserted
        summary.duplicatesSkipped = insertResult.skipped

        // ⑤
        let refundResult = applyRefunds(refunds, context: context)
        summary.refundsApplied = refundResult.applied
        summary.refundsUnmatched = refundResult.unmatched

        return summary
    }

    // MARK: - ④ 去重：数量对齐

    /// 按 (卡, 日期, 金额) 分组，服务端该组有 n 笔、本地已有 m 笔，就补插 max(0, n - m) 笔。
    ///
    /// **为什么不能用"存在即跳过"**：同一天在同一家店买两杯一样的咖啡，
    /// 是两笔完全相同的 (卡, 日期, 金额)。"存在即跳过"会把第二笔当成重复丢掉，
    /// 用户的账目就永远少一笔，而且每次同步都少。
    ///
    /// 数量对齐同时解决了两个方向：
    ///   · 同一批内部天然正确（n 就是真实笔数）
    ///   · 跨批次的重叠区间不会重复插入（m 已经包含上次插进去的）
    ///
    /// 已知副作用（接受）：用户手动删掉的 plaid 交易，下次同步会被补回来。
    /// 想删同步来的交易应该去关掉那张卡的同步 —— 设置页里写明了这个行为。
    private func insertWithCountAlignment(
        _ purchases: [(dto: PlaidTransactionDTO, card: CreditCard)],
        pointValues: [PersistentIdentifier: Double],
        context: ModelContext
    ) -> (inserted: Int, skipped: Int) {

        guard !purchases.isEmpty else { return (0, 0) }

        // 只查这批数据覆盖到的日期范围，不是全表扫描
        let dates = purchases.compactMap { $0.dto.parsedDate }
        guard let minDate = dates.min(), let maxDate = dates.max() else { return (0, 0) }

        let lower = Calendar.current.startOfDay(for: minDate)
        let upper = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: maxDate))!

        // 谓词只按日期过滤，source 和卡片在内存里筛。
        // SwiftData 的 #Predicate 对自定义 Codable 枚举和关系的支持不稳，
        // 而日期范围是它最擅长的形式 —— 用它把候选集缩到一个窗口内，剩下的自己做。
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.date >= lower && $0.date < upper })
        let existing = ((try? context.fetch(descriptor)) ?? []).filter { $0.source == .plaid }

        var localCounts: [GroupKey: Int] = [:]
        for transaction in existing {
            guard let key = GroupKey(transaction: transaction) else { continue }
            localCounts[key, default: 0] += 1
        }

        // 保持服务端返回的顺序分组，这样"补插前 n-m 笔"取到的是稳定的一批
        var grouped: [GroupKey: [(dto: PlaidTransactionDTO, card: CreditCard)]] = [:]
        for item in purchases {
            guard let key = GroupKey(dto: item.dto, card: item.card) else { continue }
            grouped[key, default: []].append(item)
        }

        var skipped = 0
        var toInsert: [(dto: PlaidTransactionDTO, card: CreditCard)] = []

        for (key, items) in grouped {
            let alreadyHave = localCounts[key] ?? 0
            let missing = max(0, items.count - alreadyHave)
            skipped += items.count - missing

            for (index, item) in items.enumerated() {
                if index < missing {
                    toInsert.append(item)
                } else {
                    PlaidSyncDebugLogger.decision(
                        item.dto,
                        verdict: "去重跳过",
                        detail: "同卡同日同金额本地已有 \(alreadyHave) 笔，服务端 \(items.count) 笔")
                }
            }
        }

        // ⚠️ 必须按日期升序插入。
        //
        // 上限（月/年额度）是**按时间顺序消耗**的：第一笔先吃额度，吃满之后
        // 后面的只能拿基础费率。而 Dictionary 的遍历顺序在 Swift 里是不确定的 ——
        // 不排序的话，同样一批数据两次同步可能把额度分给不同的交易，
        // 算出两个不同的返现总额。
        toInsert.sort { ($0.dto.parsedDate ?? .distantPast) < ($1.dto.parsedDate ?? .distantPast) }

        var inserted = 0
        for item in toInsert {
            let transaction = makeTransaction(from: item.dto, card: item.card, pointValues: pointValues)
            context.insert(transaction)

            // ⚠️ 必须挂到卡上。上限用量是从 `card.transactions` 统计出来的
            // （见 CreditCard.calculateCappedCashback 的"第三步：统计历史用量"），
            // 只 insert 不挂关系的话，同一批里后面的交易看不到前面的，
            // 每一笔都以为额度还是满的 —— 返现会被重复授予。
            // 手动记账那条路径也是这么做的。
            if item.card.transactions == nil {
                item.card.transactions = [transaction]
            } else {
                item.card.transactions?.append(transaction)
            }

            inserted += 1

            // 分段拼接：整条写成一个表达式会让 Swift 的类型检查器超时
            let cardLabel = "\(item.card.bankName) \(item.card.endNum)"
            let ratePart = String(format: "%.2f%%", transaction.rate * 100)
            let cashbackPart = String(format: "%.2f", transaction.cashbackamount)
            var detail = "\(cardLabel) / \(transaction.category.displayName)"
            detail += " / \(transaction.paymentMethod.displayName)"
            detail += " / 费率 \(ratePart) / 返现 \(cashbackPart)"
            if transaction.pointsEarned > 0 {
                detail += " / 积分 \(transaction.pointsEarned)"
            }

            PlaidSyncDebugLogger.decision(item.dto, verdict: "入库", detail: detail)
        }

        return (inserted, skipped)
    }

    /// 去重的分组键：卡 + 自然日 + 整数分金额
    private struct GroupKey: Hashable {
        let cardID: PersistentIdentifier
        let day: Date
        let amountCents: Int

        init?(dto: PlaidTransactionDTO, card: CreditCard) {
            guard let date = dto.parsedDate else { return nil }
            self.cardID = card.persistentModelID
            self.day = Calendar.current.startOfDay(for: date)
            self.amountCents = dto.amountCents
        }

        init?(transaction: Transaction) {
            guard let card = transaction.card else { return nil }
            self.cardID = card.persistentModelID
            self.day = Calendar.current.startOfDay(for: transaction.date)
            // 和 DTO 侧用同一套换算，否则两边算出来的分数对不上，去重直接失效
            self.amountCents = Int((abs(transaction.billingAmount) * 100).rounded())
        }
    }

    // MARK: - ⑤ 退款抵销

    /// 找到被退的那笔原交易并删除它。
    ///
    /// 删除即自动回冲 —— 上限用量是动态算出来的，关联的 Income 走 cascade 一起删。
    /// 所以不需要写任何"减掉之前加的返现"的逻辑，那种逻辑一旦和引擎算法不同步就会错。
    ///
    /// **退款交易本身不入库**：它的使命只是抵销，留着会让用户看到一笔金额为负的消费。
    private func applyRefunds(
        _ refunds: [(dto: PlaidTransactionDTO, card: CreditCard)],
        context: ModelContext
    ) -> (applied: Int, unmatched: Int) {

        guard !refunds.isEmpty else { return (0, 0) }

        var applied = 0
        var unmatched = 0

        for (dto, card) in refunds {
            guard let refundDate = dto.parsedDate else { continue }

            let windowStart = Calendar.current.date(
                byAdding: .day, value: -refundMatchWindowDays, to: refundDate)!
            // 加一天上界：原交易和退款可能是同一天
            let windowEnd = Calendar.current.date(
                byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: refundDate))!

            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.date >= windowStart && $0.date < windowEnd })

            let candidates = ((try? context.fetch(descriptor)) ?? [])
                .filter { $0.source == .plaid }
                .filter { $0.card?.persistentModelID == card.persistentModelID }
                .filter { Int((abs($0.billingAmount) * 100).rounded()) == dto.amountCents }
                // 日期最接近且不晚于退款日的那笔最可能是原交易
                .sorted { $0.date > $1.date }

            if let original = candidates.first {
                PlaidSyncDebugLogger.decision(
                    dto,
                    verdict: "退款已抵销",
                    detail: "删除原交易「\(original.merchant)」\(original.dateString)"
                        + " \(String(format: "%.2f", original.billingAmount))")
                context.delete(original)
                applied += 1
            } else {
                // 找不到匹配很正常：原交易可能发生在首次全量的回溯范围之前。
                // 记日志但不做任何事 —— 猜一笔来删是绝对不能做的。
                unmatched += 1
                PlaidSyncDebugLogger.decision(
                    dto,
                    verdict: "退款未匹配",
                    detail: "\(refundMatchMessage(card: card)) 内找不到等额原交易，已忽略")
            }
        }

        return (applied, unmatched)
    }

    private func refundMatchMessage(card: CreditCard) -> String {
        "\(card.bankName) \(card.endNum) 前 \(refundMatchWindowDays) 天"
    }

    // MARK: - 建模型

    /// 用**和手动记账完全相同**的方式算奖励，再交给构造器。
    ///
    /// ⚠️ 不能只把 card 传给 `Transaction.init` 就指望它算对。
    /// 那个构造器在 `cashbackAmount` 为 nil 时走的是
    /// `cashbackamount = billingAmount * nominalRate` 这条**朴素兜底**路径，它：
    ///
    ///   · **完全不认识积分卡** —— 积分卡的"费率"是每元多少积分（Amex 可能是 300），
    ///     直接乘上去就变成一笔天文数字的"返现"
    ///   · **完全不考虑上限** —— 月/年额度、类别额度、支付方式额度全部失效
    ///
    /// 真正的奖励引擎是 `CreditCard.calculateCappedPoints` / `calculateCappedCashback`，
    /// 手动记账走的就是它们。这里必须一致，否则同一笔消费手动记和自动同步会得出两个数。
    // internal（而非 private）是为了让测试能直接验证奖励计算 —— 这是最容易
    // 算错、而且算错了用户也看不出来的一段
    func makeTransaction(from dto: PlaidTransactionDTO,
                         card: CreditCard,
                         pointValues: [PersistentIdentifier: Double]) -> Transaction {

        let amount = abs(dto.amount)
        let category = PlaidCategoryMapping.category(primary: dto.category, detailed: dto.categoryDetailed)
        let paymentMethod = PlaidCategoryMapping.paymentMethod(from: dto.paymentChannel)
        let date = dto.parsedDate ?? Date()

        var finalCashback: Double = 0
        var pointsEarned: Int = 0

        if card.rewardType == .points {
            let result = card.calculateCappedPoints(
                amount: amount,
                category: category,
                // Plaid 只支持美国，交易地固定 .us
                location: .us,
                date: date,
                paymentMethod: paymentMethod,
                pointValueInCardCurrency: pointValues[card.persistentModelID] ?? 0)
            pointsEarned = result.points
            // 积分卡的 cashbackamount 存的是积分折算出的**价值**，和手动记账一致
            finalCashback = result.value
        } else {
            finalCashback = card.calculateCappedCashback(
                amount: amount,
                category: category,
                location: .us,
                date: date,
                paymentMethod: paymentMethod)
        }

        return Transaction(
            merchant: dto.resolvedMerchant,
            category: category,
            location: .us,
            // Plaid 给的是**结算后**金额，没有原始外币金额这个字段，
            // 所以 amount 和 billingAmount 是同一个数
            amount: amount,
            date: date,
            card: card,
            billingAmount: amount,
            cashbackAmount: finalCashback,
            pointsEarned: pointsEarned,
            paymentMethod: paymentMethod,
            billingCurrencyCode: dto.currency ?? "USD",
            source: .plaid)
    }

    // MARK: - 辅助

    private func syncableAccounts(itemId: String, context: ModelContext) -> [LinkedBankAccount] {
        let descriptor = FetchDescriptor<LinkedBankAccount>(
            predicate: #Predicate { $0.itemId == itemId })
        return ((try? context.fetch(descriptor)) ?? []).filter(\.isSyncable)
    }

    /// 增量窗口：`max(14 天, 距上次同步 + 7 天)`。
    ///
    /// 多回看 7 天是为了覆盖 pending→posted 的延迟和银行晚报的交易，
    /// 重叠部分由数量对齐去重吸收，多拉不会产生重复。
    /// （Plaid 文档对 DEFAULT_UPDATE 后的建议也是取 7–14 天，一致。）
    private func incrementalStart(for accounts: [LinkedBankAccount], end: Date) -> Date {
        // 取最旧的水位线：同一个 item 下不同卡的 lastSyncedAt 可能不一致
        // （比如某张卡中途才打开同步），按最旧的算才不会漏。
        let oldest = accounts.compactMap(\.lastSyncedAt).min()

        var days = minIncrementalDays
        if let oldest {
            let elapsed = Calendar.current.dateComponents([.day], from: oldest, to: end).day ?? 0
            days = max(minIncrementalDays, elapsed + incrementalOverlapDays)
        }
        return Calendar.current.date(byAdding: .day, value: -days, to: end)!
    }

    private static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()
}
