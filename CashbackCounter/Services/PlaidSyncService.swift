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
//  4. **永远不删交易。** 退款作为一笔负数交易入库来抵销原消费，
//     而不是去删原消费 —— 删除方案曾经每次同步都多删掉一笔真实消费（见 ④ 的注释）。
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

    /// 正在跑的同步数（含首次绑定时的等待重试）。isSyncing 由它派生：
    /// 之前是谁结束谁置 false，并发的两次里先完成的会把另一次的遮罩关掉、按钮放开。
    private var activeOperations = 0 {
        didSet {
            isSyncing = activeOperations > 0
            if activeOperations == 0 { statusMessage = nil }
        }
    }

    /// 每个 item 同一时刻只跑一次。冷启动时 `.task` 和 scenePhase→active 几乎同时触发
    /// syncIfNeededToday，再加下拉刷新和推送，之前会并发把同一段历史拉两遍；
    /// 后来的直接等前一次的结果。
    private var inFlight: [String: Task<SyncSummary, Error>] = [:]

    /// 绑定后的头几天每天再全量拉一次。
    ///
    /// Plaid 在 INITIAL_UPDATE 后只给约 30 天，完整的 24 个月要等 HISTORICAL_UPDATE
    /// （几分钟到几小时后）。首次成功就把 didInitialSync 置 true 的话，剩下的历史永远不会再拉 ——
    /// 之后全是 14 天的增量。后端没转发这个 webhook，所以用时间兜底：数量对齐保证重复拉取
    /// 不产生重复，代价只是头一周每天多一次全量请求。
    static let historicalRefreshWindowDays = 7
    static let historicalRefreshInterval: TimeInterval = 20 * 3600

    private let api = PlaidAPIClient.shared

    private init() {}

    // MARK: - 结果

    struct SyncSummary {
        /// 新入库的消费笔数
        var inserted = 0
        /// 新入库的退款笔数（作为负数交易）
        var refundsApplied = 0
        /// 找不到原消费、被忽略的退款笔数
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

    /// 同步一个 item。内部自己判断该走首次全量还是增量。同一个 item 的并发调用共用一次。
    @discardableResult
    func sync(itemId: String, context: ModelContext) async throws -> SyncSummary {
        if let running = inFlight[itemId] {
            return try await running.value
        }
        let task = Task<SyncSummary, Error> { [self] in
            try await performSync(itemId: itemId, context: context)
        }
        inFlight[itemId] = task
        defer { inFlight[itemId] = nil }
        return try await task.value
    }

    private func performSync(itemId: String, context: ModelContext) async throws -> SyncSummary {
        activeOperations += 1
        defer { activeOperations -= 1 }

        let accounts = syncableAccounts(itemId: itemId, context: context)
        guard !accounts.isEmpty else { return SyncSummary() }

        let now = Date()
        let needsInitial = accounts.contains { !$0.didInitialSync }
        let repeatsFullPull = !needsInitial && accounts.contains { Self.shouldRepeatFullPull(for: $0, now: now) }
        let isFullPull = needsInitial || repeatsFullPull

        let (start, end): (Date, Date)
        if isFullPull {
            statusMessage = needsInitial ? String.loc("正在导入历史交易…") : String.loc("正在补齐历史交易…")
            end = now
            start = Calendar.current.date(byAdding: .day, value: -maxLookbackDays, to: end)!
        } else {
            statusMessage = String.loc("正在同步…")
            end = now
            start = incrementalStart(for: accounts, end: end)
        }

        let transactions = try await fetchRange(itemId: itemId, start: start, end: end)
        PlaidSyncDebugLogger.dumpFetched(transactions, itemId: itemId)

        statusMessage = String.loc("正在处理 \(transactions.count) 笔交易…")

        // 积分估值可能要查汇率（网络），所以**每张卡只解析一次**、在进入管线之前做完。
        // 放进循环里会变成每笔交易一次网络往返。
        let pointValues = await resolvePointValues(for: accounts)

        let summary = await process(transactions, accounts: accounts, pointValues: pointValues, context: context)

        let finishedAt = Date()
        for account in accounts {
            account.lastSyncedAt = finishedAt
            account.didInitialSync = true
            if isFullPull {
                Self.recordFullPull(for: account, at: finishedAt)
            }
        }
        try context.save()

        let text = "新增 \(summary.inserted)、退款入库 \(summary.refundsApplied)（未匹配 \(summary.refundsUnmatched)）、"
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
        // 整个等待重试期间都算"在同步"。之前在 sleep 前手动置 true、靠下一次 sync 的 defer 复位，
        // sleep 被取消时就永远停在 true：遮罩不消失、按钮全禁用
        activeOperations += 1
        defer { activeOperations -= 1 }

        for attempt in 0...productNotReadyRetries {
            do {
                return try await sync(itemId: itemId, context: context)
            } catch let error as PlaidAPIError where error.isProductNotReady {
                guard attempt < productNotReadyRetries else { throw error }
                statusMessage = String.loc("银行数据正在准备中…（\(attempt + 1)/\(productNotReadyRetries)）")
                try await Task.sleep(for: productNotReadyInterval)
            }
        }
        return SyncSummary()
    }

    // MARK: - 历史补拉

    static func fullPullDefaultsKey(for accountId: String) -> String {
        "plaid_last_full_pull_\(accountId)"
    }

    /// 绑定后 7 天内、距上次全量拉取超过 20 小时 → 再全量拉一次（见 historicalRefreshWindowDays）
    static func shouldRepeatFullPull(for account: LinkedBankAccount, now: Date,
                                     defaults: UserDefaults = .standard) -> Bool {
        guard account.didInitialSync else { return false }
        guard let windowEnd = Calendar.current.date(byAdding: .day, value: historicalRefreshWindowDays, to: account.linkedAt),
              now < windowEnd else { return false }
        guard let last = defaults.object(forKey: fullPullDefaultsKey(for: account.accountId)) as? Date else { return true }
        return now.timeIntervalSince(last) >= historicalRefreshInterval
    }

    static func recordFullPull(for account: LinkedBankAccount, at date: Date,
                               defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: fullPullDefaultsKey(for: account.accountId))
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

    /// 单批数据的完整处理。顺序：
    ///
    ///   ① 只留开了同步的账户  ② 丢弃 pending  ③ 按符号分流
    ///   ④ 退款配对（找得到原消费的才入库）  ⑤ 消费 + 退款一起按数量对齐入库
    ///
    /// 退款**作为一笔负数交易入库**，而不是删掉原消费。
    /// 删除方案曾造成真实的数据丢失：退款 DTO 不入库、也没有"已抵销"标记，
    /// 而增量窗口至少回看 14 天，同一笔退款会被连续拉回十几次 ——
    /// 第一次删对了原交易，之后每次都按"同卡、90 天内、等额"再删一笔**别的**真实消费
    /// （订阅类月费必中）。负数入库后去重键自带符号，重复拉回只会被数量对齐跳过。
    // internal（而非 private）是为了让测试能直接验证幂等性
    func process(_ transactions: [PlaidTransactionDTO],
                 accounts: [LinkedBankAccount],
                 pointValues: [PersistentIdentifier: Double],
                 context: ModelContext) async -> SyncSummary {

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
                    PlaidSyncDebugLogger.decision(dto, verdict: "退款", detail: "待配对原消费")
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

        // ④ 退款配对：只有找得到对应消费（本批里或库里）的退款才入库。
        //
        // 找不到的一律忽略：原消费可能早于首次导入范围，也可能已被旧版本的"删除抵销"
        // 处理过 —— 那种情况下再入一笔负数就是双倍扣减。宁可少算一笔退款，也不凭空造负数。
        let matchedRefunds = matchRefunds(refunds, against: purchases, context: context)
        summary.refundsUnmatched = refunds.count - matchedRefunds.count

        // ⑤ 消费和退款一起数量对齐入库（按日期升序，退款自然排在原消费之后）
        let insertResult = await insertWithCountAlignment(purchases + matchedRefunds, pointValues: pointValues, context: context)
        summary.inserted = insertResult.insertedPurchases
        summary.refundsApplied = insertResult.insertedRefunds
        summary.duplicatesSkipped = insertResult.skipped

        return summary
    }

    // MARK: - ④ 退款配对

    /// 给每笔退款找原消费：先在本批消费里找，再到库里找（同卡、退款日前 90 天内、等额、source == .plaid）。
    /// 找得到就让它入库，找不到就忽略 —— 永远不去删任何一笔。
    private func matchRefunds(
        _ refunds: [(dto: PlaidTransactionDTO, card: CreditCard)],
        against purchases: [(dto: PlaidTransactionDTO, card: CreditCard)],
        context: ModelContext
    ) -> [(dto: PlaidTransactionDTO, card: CreditCard)] {

        guard !refunds.isEmpty else { return [] }

        // 库里的候选一次查完整个窗口，再在内存里按卡 / 金额筛
        let calendar = Calendar.current
        var existing: [Transaction] = []
        let refundDates = refunds.compactMap { $0.dto.parsedDate }
        if let minDate = refundDates.min(), let maxDate = refundDates.max() {
            let lower = calendar.date(byAdding: .day, value: -(refundMatchWindowDays + 1), to: minDate)!
            let upper = calendar.date(byAdding: .day, value: 2, to: maxDate)!
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.date >= lower && $0.date < upper })
            existing = ((try? context.fetch(descriptor)) ?? [])
                .filter { $0.source == .plaid && $0.billingAmount > 0 }
        }

        var matched: [(dto: PlaidTransactionDTO, card: CreditCard)] = []
        for (dto, card) in refunds {
            guard let refundDate = dto.parsedDate else { continue }
            let windowStart = calendar.date(byAdding: .day, value: -refundMatchWindowDays, to: refundDate)!
            // 加一天上界：原消费和退款可能是同一天
            let windowEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: refundDate))!
            let cents = dto.amountCents
            let cardID = card.persistentModelID
            let merchant = dto.resolvedMerchant.lowercased()

            let inBatch = purchases.filter { item in
                item.card.persistentModelID == cardID
                    && item.dto.amountCents == cents
                    && item.dto.dayKey <= dto.dayKey
                    && (item.dto.parsedDate ?? .distantPast) >= windowStart
            }
            let inStore = existing.filter { t in
                t.card?.persistentModelID == cardID
                    && Int((t.billingAmount * 100).rounded()) == cents
                    && t.date >= windowStart && t.date < windowEnd
            }

            if inBatch.isEmpty && inStore.isEmpty {
                PlaidSyncDebugLogger.decision(
                    dto, verdict: "退款未匹配",
                    detail: "\(card.bankName) \(card.endNum) 前 \(refundMatchWindowDays) 天内找不到等额原消费，已忽略")
                continue
            }

            let sameMerchant = inBatch.contains { $0.dto.resolvedMerchant.lowercased() == merchant }
                || inStore.contains { $0.merchant.lowercased() == merchant }
            matched.append((dto, card))
            PlaidSyncDebugLogger.decision(
                dto, verdict: "退款入库",
                detail: sameMerchant ? "找到同商户原消费，按负数交易入库" : "找到等额原消费（商户不同），按负数交易入库")
        }
        return matched
    }

    // MARK: - ⑤ 去重：数量对齐

    /// 按 (卡, 日期, 带符号金额) 分组，服务端该组有 n 笔、本地已有 m 笔，就补插 max(0, n - m) 笔。
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
        _ items: [(dto: PlaidTransactionDTO, card: CreditCard)],
        pointValues: [PersistentIdentifier: Double],
        context: ModelContext
    ) async -> (insertedPurchases: Int, insertedRefunds: Int, skipped: Int) {

        guard !items.isEmpty else { return (0, 0, 0) }

        // 只查这批数据覆盖到的日期范围，不是全表扫描
        let dates = items.compactMap { $0.dto.parsedDate }
        guard let minDate = dates.min(), let maxDate = dates.max() else { return (0, 0, 0) }

        // 两头各多放一天：旧行的 Date 是在当时的时区按本地午夜存的，换过时区后
        // 可能落到窗口边缘之外几个小时。多拉一天只是多几条候选，少拉会漏掉它们而重复插入。
        let lower = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: minDate))!
        let upper = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: maxDate))!

        // 谓词只按日期过滤，source 和卡片在内存里筛。
        // SwiftData 的 #Predicate 对自定义 Codable 枚举和关系的支持不稳，
        // 而日期范围是它最擅长的形式 —— 用它把候选集缩到一个窗口内，剩下的自己做。
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.date >= lower && $0.date < upper })
        let existing = ((try? context.fetch(descriptor)) ?? []).filter { $0.source == .plaid }

        var localCounts: [GroupKey: Int] = [:]
        var legacyRows: [GroupKey: [Transaction]] = [:]
        for transaction in existing {
            guard let key = GroupKey(transaction: transaction) else { continue }
            localCounts[key, default: 0] += 1
            if !Self.isPlaidDedupeID(transaction.dedupeID) {
                legacyRows[key, default: []].append(transaction)
            }
        }

        // 保持服务端返回的顺序分组，这样"补插前 n-m 笔"取到的是稳定的一批
        var grouped: [GroupKey: [(dto: PlaidTransactionDTO, card: CreditCard)]] = [:]
        for item in items {
            guard let key = GroupKey(dto: item.dto, card: item.card) else { continue }
            grouped[key, default: []].append(item)
        }

        var skipped = 0
        var toInsert: [(dto: PlaidTransactionDTO, card: CreditCard)] = []

        for (key, groupItems) in grouped {
            let alreadyHave = localCounts[key] ?? 0
            let missing = max(0, groupItems.count - alreadyHave)
            skipped += groupItems.count - missing

            // 旧版本同步进来的行（dedupeID 还是裸 UUID）：既然这次按日期对上了服务端分组，
            // 就把分组键写进 dedupeID，以后换时区也不会再对不上。
            // 用旧 UUID 当 token：CloudKit 复制出来的副本共用同一个 UUID，升级后仍然共用，
            // 交易去重照样能认出它们。
            for row in legacyRows[key] ?? [] {
                row.dedupeID = Self.plaidDedupeID(dayKey: key.day, cents: key.cents, token: row.dedupeID)
            }

            for (index, item) in groupItems.enumerated() {
                if index < missing {
                    toInsert.append(item)
                } else {
                    PlaidSyncDebugLogger.decision(
                        item.dto,
                        verdict: "去重跳过",
                        detail: "同卡同日同金额本地已有 \(alreadyHave) 笔，服务端 \(groupItems.count) 笔")
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

        var insertedPurchases = 0
        var insertedRefunds = 0
        // 插入后要重算的 (卡, 周期)：补进来的行可能早于已有交易，额度要重新按时间顺序分配。
        // 奖励**不在这里逐笔算**：逐笔算每次都要扫一遍 card.transactions，2 年 × 100 笔/月
        // 的初次导入是几百万次迭代、全在主线程；交给结尾的周期重算一次算完。
        var affectedPeriods: [PersistentIdentifier: (card: CreditCard, periods: Set<CreditCard.PeriodKey>, rows: [Transaction])] = [:]
        for item in toInsert {
            let transaction = makeTransaction(from: item.dto, card: item.card, pointValues: pointValues, computeReward: false)
            context.insert(transaction)

            if item.dto.isInflow {
                insertedRefunds += 1
            } else {
                insertedPurchases += 1
            }
            affectedPeriods[item.card.persistentModelID, default: (item.card, [], [])]
                .periods.insert(item.card.periodKey(for: transaction.date))
            affectedPeriods[item.card.persistentModelID]?.rows.append(transaction)

            // 大批量时隔几十笔让一次主线程：状态文案能刷出来，界面不至于整段冻住
            if (insertedPurchases + insertedRefunds) % 50 == 0 {
                await Task.yield()
            }

            // 分段拼接：整条写成一个表达式会让 Swift 的类型检查器超时
            let cardLabel = "\(item.card.bankName) \(item.card.endNum)"
            let ratePart = String(format: "%.2f%%", transaction.rate * 100)
            var detail = "\(cardLabel) / \(transaction.category.displayName)"
            detail += " / \(transaction.paymentMethod.displayName)"
            detail += " / 名义费率 \(ratePart)（奖励在周期重算后写入）"

            PlaidSyncDebugLogger.decision(item.dto, verdict: item.dto.isInflow ? "退款入库" : "入库", detail: detail)
        }

        for (_, entry) in affectedPeriods {
            // ⚠️ 必须挂到卡上：上限用量是从 `card.transactions` 统计出来的，只 insert 不挂关系
            // 的话重算看不到这些行。每张卡整批挂一次，而不是逐笔 append 触发整个关系数组重写
            let current = entry.card.transactions ?? []
            let present = Set(current.map { ObjectIdentifier($0) })
            let missing = entry.rows.filter { !present.contains(ObjectIdentifier($0)) }
            if !missing.isEmpty {
                entry.card.transactions = current + missing
            }

            let pointValue = pointValues[entry.card.persistentModelID] ?? 0
            for period in entry.periods {
                entry.card.recalculateRewards(periodKey: period, pointValueInCardCurrency: pointValue)
            }
        }

        return (insertedPurchases, insertedRefunds, skipped)
    }

    /// 去重的分组键：卡 + 自然日（字符串）+ 带符号的整数分金额。
    ///
    /// 日期用 `yyyy-MM-dd` 字符串而不是 Date：同步行把它写进了 dedupeID，
    /// 取出来和服务端的 date 字段直接比，不经过任何时区换算。
    private struct GroupKey: Hashable {
        let cardID: PersistentIdentifier
        let day: String
        let cents: Int

        init?(dto: PlaidTransactionDTO, card: CreditCard) {
            guard dto.parsedDate != nil else { return nil }
            self.cardID = card.persistentModelID
            self.day = dto.dayKey
            self.cents = dto.signedBillingCents
        }

        init?(transaction: Transaction) {
            guard let card = transaction.card else { return nil }
            self.cardID = card.persistentModelID
            if let parsed = PlaidSyncService.parsePlaidDedupeID(transaction.dedupeID) {
                self.day = parsed.day
                self.cents = parsed.cents
            } else {
                // 旧版本同步的行：只能从 Date 按当前时区推自然日，
                // 和它当初被写入时用的是同一套本地午夜约定
                self.day = PlaidSyncService.localDayFormatter.string(from: transaction.date)
                // 和 DTO 侧用同一套换算，否则两边算出来的分数对不上，去重直接失效
                self.cents = Int((transaction.billingAmount * 100).rounded())
            }
        }
    }

    /// 交易地区：按结算币种反查，查不到就按发卡地。
    ///
    /// 之前固定写 `.us`：非美国发卡的卡（Plaid 也支持加拿大 / 英国 / 欧洲机构）会被
    /// `rewardTrack(for: .us)` 判成外币轨道，用外币费率和外币上限，而入账币种却写成 GBP / CAD。
    /// Plaid 不给原始消费地，只有结算币种，所以这是能拿到的最好近似。
    static func location(for dto: PlaidTransactionDTO, card: CreditCard) -> Region {
        Region.from(currencyCode: dto.currency ?? "") ?? card.issueRegion
    }

    // MARK: - 同步行的 dedupeID

    /// 同步进来的行把分组键写进 `dedupeID`：`plaid|yyyy-MM-dd|<带符号的分>|<token>`。
    /// 前三段就是 GroupKey（时区无关），token 保证全局唯一；CloudKit 复制出的副本会连 token 一起复制，
    /// 所以 `CardTemplateManager.deduplicateTransactions` 仍能按整串相等把副本认出来。
    static let plaidDedupePrefix = "plaid"

    static func plaidDedupeID(dayKey: String, cents: Int, token: String) -> String {
        let safeToken = token.isEmpty ? UUID().uuidString : token
        return [plaidDedupePrefix, dayKey, String(cents), safeToken].joined(separator: "|")
    }

    static func parsePlaidDedupeID(_ id: String) -> (day: String, cents: Int)? {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == plaidDedupePrefix, let cents = Int(parts[2]) else { return nil }
        return (String(parts[1]), cents)
    }

    static func isPlaidDedupeID(_ id: String) -> Bool {
        parsePlaidDedupeID(id) != nil
    }

    /// 旧行推自然日用的格式器：和 `PlaidTransactionDTO.parsedDate` 一样是本地时区 + 公历 + POSIX
    static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

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
                         pointValues: [PersistentIdentifier: Double],
                         computeReward: Bool = true) -> Transaction {

        // 消费为正、退款为负：退款作为负数交易入库，返现跟着回冲
        let amount = dto.isInflow ? -abs(dto.amount) : abs(dto.amount)
        let category = PlaidCategoryMapping.category(primary: dto.category, detailed: dto.categoryDetailed)
        let paymentMethod = PlaidCategoryMapping.paymentMethod(from: dto.paymentChannel)
        let date = dto.parsedDate ?? Date()
        let location = Self.location(for: dto, card: card)

        var finalCashback: Double = 0
        var pointsEarned: Int = 0

        if !computeReward {
            // 批量插入：奖励留给周期重算统一写，这里只占位
        } else if card.rewardType == .points {
            let result = card.calculateCappedPoints(
                amount: amount,
                category: category,
                location: location,
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
                location: location,
                date: date,
                paymentMethod: paymentMethod)
        }

        let transaction = Transaction(
            merchant: dto.resolvedMerchant,
            category: category,
            location: location,
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
        // 分组键写进 dedupeID，去重不再依赖当前时区（见 GroupKey）
        transaction.dedupeID = Self.plaidDedupeID(
            dayKey: dto.dayKey, cents: dto.signedBillingCents, token: UUID().uuidString)
        if !computeReward {
            // 构造器在 cashbackAmount 给定时按它反推 rate；占位 0 会把名义费率也写成 0
            transaction.rate = card.getRate(for: category, location: location, payment: paymentMethod)
        }
        return transaction
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
