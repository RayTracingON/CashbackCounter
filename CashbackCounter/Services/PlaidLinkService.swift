//
//  PlaidLinkService.swift
//  CashbackCounter
//
//  绑定银行的编排：link_token → Link 弹窗 → public_token → item_id → 账户列表 → 匹配卡片。
//
//  LinkKit 那一段（弹窗本身）由 SwiftUI 的 PlaidLinkView 负责，
//  这里只处理它前后的网络往来和落库。
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PlaidLinkService {

    static let shared = PlaidLinkService()

    private let api = PlaidAPIClient.shared

    private init() {}

    // MARK: - 结果

    /// 一次绑定完成后，每个账户的归属情况。
    /// UI 拿它决定要不要弹卡片选择器。
    enum AccountMatch {
        /// 尾号唯一命中，已自动关联并打开同步
        case matched(LinkedBankAccount)
        /// 多张卡是同一个尾号，必须让用户挑
        case ambiguous(LinkedBankAccount, candidates: [CreditCard])
        /// 卡包里没有这个尾号的卡
        case unmatched(LinkedBankAccount)
    }

    /// `reconcileAccounts` 的结果。
    ///
    /// 不用一个 Int 表达，是因为「Plaid 一个账户都没返回」和「正常移除了 0 个」
    /// 必须分开：前者是可疑状态，本地一条都不能删，得让用户来判断。
    /// 混在一起的话，后端或机构侧的一次临时空响应就会把一整家银行的
    /// syncEnabled / didInitialSync / card 关联全部抹掉，且不可逆。
    enum ReconcileResult: Equatable {
        /// 正常对齐。removed / added 供 UI 提示
        case aligned(removed: Int, added: Int)
        /// Plaid 侧一个账户都没返回。**本地未做任何改动**
        case noRemoteAccounts
    }

    struct LinkResult {
        let itemId: String
        let institutionName: String
        let matches: [AccountMatch]

        /// 需要用户介入的账户数量
        var needsAttention: Int {
            matches.filter {
                if case .matched = $0 { return false }
                return true
            }.count
        }
    }

    // MARK: - 第 1 步：拿 link_token

    func createLinkToken() async throws -> String {
        let response: LinkTokenResponse = try await api.post("/api/plaid/link-token")
        return response.linkToken
    }

    // MARK: - 第 2 步：Link 成功后收尾

    /// 用 public_token 换 item_id，拉账户列表，逐个建本地记录并尝试匹配卡片。
    ///
    /// ⚠️ public_token **30 分钟过期且只能用一次** —— 这个方法失败了不能简单重试，
    /// 必须让用户重走一遍 Link 弹窗。
    func completeLink(publicToken: String,
                      institutionName: String,
                      context: ModelContext) async throws -> LinkResult {

        let exchange: ExchangeResponse = try await api.post(
            "/api/plaid/exchange",
            body: ExchangeRequest(publicToken: publicToken))

        let accounts: [PlaidAccountDTO] = try await api.get(
            "/api/plaid/accounts",
            query: [URLQueryItem(name: "itemId", value: exchange.itemId)])

        let cards = (try? context.fetch(FetchDescriptor<CreditCard>())) ?? []
        var matches: [AccountMatch] = []

        for dto in accounts {
            // 同一个账户重复绑定（用户又走了一遍 Link）时不要建重复记录，
            // 沿用已有的那条，保住它的 syncEnabled / lastSyncedAt / didInitialSync。
            // 丢掉 didInitialSync 的后果是下次同步又跑一次 730 天的全量。
            if let existing = findAccount(itemId: exchange.itemId, accountId: dto.accountId, context: context) {
                existing.institutionName = institutionName
                existing.accountName = dto.name ?? existing.accountName
                existing.mask = dto.mask ?? existing.mask
                matches.append(.matched(existing))
                continue
            }

            let account = LinkedBankAccount(
                itemId: exchange.itemId,
                accountId: dto.accountId,
                institutionName: institutionName,
                accountName: dto.name ?? dto.officialName ?? String(localized: "信用卡"),
                mask: dto.mask ?? "")

            context.insert(account)
            matches.append(match(account: account, against: cards))
        }

        try context.save()

        return LinkResult(
            itemId: exchange.itemId,
            institutionName: institutionName,
            matches: matches)
    }

    // MARK: - 卡片匹配

    /// 按尾号匹配。
    ///
    /// 尾号是 Plaid 能给的最详细的卡标识 —— **完整卡号任何产品都不提供**（PCI DSS）。
    /// 所以匹配只可能做到这个精度，剩下的歧义交给用户。
    private func match(account: LinkedBankAccount, against cards: [CreditCard]) -> AccountMatch {
        guard !account.mask.isEmpty else {
            return .unmatched(account)
        }

        let candidates = cards.filter { $0.endNum == account.mask }

        switch candidates.count {
        case 1:
            account.card = candidates[0]
            // 唯一命中才默认打开同步。这是这里唯一会自动开启同步的路径 ——
            // 没匹配到卡就没有费率规则，同步进来的交易算不出返现和积分。
            account.syncEnabled = true
            return .matched(account)

        case 0:
            return .unmatched(account)

        default:
            // 同尾号多张卡（不同银行完全可能撞尾号），猜错就是把交易记到别的卡上，
            // 连带费率和上限全错。必须问用户。
            return .ambiguous(account, candidates: candidates)
        }
    }

    /// 用户在选择器里挑好之后调用
    func assign(card: CreditCard, to account: LinkedBankAccount, context: ModelContext) {
        account.card = card
        account.syncEnabled = true
        try? context.save()
    }

    // MARK: - Update mode：管理已连接的账户

    /// 铸一个 update mode 的 link_token，用于让用户重新选择共享哪些账户。
    ///
    /// 这是**单独摘掉一张卡**的唯一途径 —— Plaid 的 `/item/remove` 是 item 粒度的，
    /// 一次绑定下面挂着多张卡时它只能全解，官方没有「移除单个 account」的接口。
    ///
    /// ⚠️ 用这个 token 走完 Link 之后**绝不能**调 `completeLink`：
    /// 它第一件事就是 `/api/plaid/exchange`，那会换出一个**新的 itemId**，
    /// 同一家银行凭空多一份绑定并开始重复计费。
    /// update mode 下 access_token 和 itemId 都没变，收尾走 `reconcileAccounts`。
    func createUpdateLinkToken(itemId: String) async throws -> String {
        let response: LinkTokenResponse = try await api.post(
            "/api/plaid/link-token/update",
            query: [URLQueryItem(name: "itemId", value: itemId)])
        return response.linkToken
    }

    /// Link update mode 结束后，把本地账户列表对齐到 Plaid 的最新状态。
    ///
    /// **保守失败**是这里的底线，和同步引擎的第三条原则一致（宁可少算不要多算）：
    /// 读不到远端账户列表时**一条本地记录都不动**，把错误抛给 UI。
    /// 把「读不到」当成「用户取消了这些账户」，会静默删掉还在正常同步的卡，
    /// 而用户在界面上完全看不出发生过什么。
    @discardableResult
    func reconcileAccounts(itemId: String, context: ModelContext) async throws -> ReconcileResult {
        let remote: [PlaidAccountDTO]
        do {
            remote = try await api.get(
                "/api/plaid/accounts",
                query: [URLQueryItem(name: "itemId", value: itemId)])

        } catch PlaidAPIError.server(let status, _) where status == 404 {
            // 后端不认识这个 item。和 unlink 的处理一致：认为它已经不在了。
            // 留着本地这份镜像只会变成一条永远删不掉的僵尸记录 ——
            // 再点多少次「管理账户」，后端都只会回 404。
            let stale = accounts(itemId: itemId, context: context)
            for account in stale { context.delete(account) }
            try context.save()
            print("ℹ️ 后端已无此绑定（404），清理本地记录: itemId=\(itemId)")
            return .aligned(removed: stale.count, added: 0)
        }
        // 其它错误（网络 / 401 / 502 / 超时）原样抛出去，本地保持不动。

        return try reconcile(itemId: itemId, remote: remote, context: context)
    }

    /// `reconcileAccounts` 的纯逻辑部分 —— 不碰网络，便于单测。
    ///
    /// 三种账户的处理各有理由：
    ///   · 远端没有的 → 删（用户在 update mode 里取消了勾选，Plaid 已撤权）
    ///   · 本地没有的 → 建（用户**新勾选**了账户；漏掉的话它在 App 里完全不可见）
    ///   · 两边都有的 → **原样不动**，保住 syncEnabled / lastSyncedAt /
    ///     didInitialSync / card。丢掉 didInitialSync 的后果是下次同步重跑 730 天全量
    @discardableResult
    func reconcile(itemId: String,
                   remote: [PlaidAccountDTO],
                   context: ModelContext) throws -> ReconcileResult {

        let local = accounts(itemId: itemId, context: context)

        // 空数组视为**可疑**，不当成「用户取消了全部账户」。
        // Plaid 的账户选择页本身不允许一个都不勾，所以真收到空数组更可能是
        // 后端或机构侧的临时状态。照着删就是把一整家银行的本地状态一次抹掉。
        guard !remote.isEmpty else { return .noRemoteAccounts }

        let remoteIds = Set(remote.map(\.accountId))
        let localIds = Set(local.map(\.accountId))

        // 银行名从现有记录上取：update mode 不经过 Link 的 metadata，拿不到
        // institution.name，而同一个 item 下的账户本来就都属于同一家银行。
        let institutionName = local.first?.institutionName ?? String(localized: "未知银行")

        var removed = 0
        for account in local where !remoteIds.contains(account.accountId) {
            context.delete(account)
            removed += 1
        }

        let cards = (try? context.fetch(FetchDescriptor<CreditCard>())) ?? []

        var added = 0
        for dto in remote where !localIds.contains(dto.accountId) {
            let account = LinkedBankAccount(
                itemId: itemId,
                accountId: dto.accountId,
                institutionName: institutionName,
                accountName: dto.name ?? dto.officialName ?? String(localized: "信用卡"),
                mask: dto.mask ?? "")

            context.insert(account)
            // 尾号匹配走和初次绑定完全相同的一条路径 —— 唯一命中才自动开同步
            _ = match(account: account, against: cards)
            added += 1
        }

        try context.save()
        return .aligned(removed: removed, added: added)
    }

    // MARK: - 解绑

    /// 解绑一家银行。
    ///
    /// 后端保证正确的顺序：先调 Plaid `/item/remove` 撤销授权，成功后才删自己的记录。
    /// 所以这里等它成功了再删本地的 LinkedBankAccount。
    ///
    /// **已导入的交易一律保留** —— 历史账目不该因为解绑而消失，
    /// 那些消费是真实发生过的，用户的返现统计也建立在它们之上。
    func unlink(itemId: String, context: ModelContext) async throws {
        do {
            let _: UnlinkResponse = try await api.post(
                "/api/plaid/unlink",
                query: [URLQueryItem(name: "itemId", value: itemId)])

        } catch PlaidAPIError.server(let status, _) where status == 404 {
            // 后端不认识这个 item。两种情况都意味着**它已经不在了**：
            //   · 之前删过账号 / 解绑过，后端记录早没了，只有本地这份镜像还留着
            //   · 当前登录的是另一个账号，这条记录属于上一个账号
            //
            // 归属校验做在查询条件里，所以"别人的 item"和"不存在的 item"
            // 在后端是同一个 404 —— 两者本地都该清理掉。
            //
            // 把它当失败弹给用户是错的：那会留下一条**永远删不掉**的僵尸记录，
            // 因为再点多少次后端都只会回 404。
            print("ℹ️ 后端已无此绑定（404），清理本地记录: itemId=\(itemId)")
        }

        // 只有确认后端侧已经没有它了（成功解绑 或 本来就不存在）才删本地。
        // 其它错误（401 / 网络 / 502）会从上面抛出去，本地记录保留 ——
        // 那是下次重试的依据，不能因为一次网络抖动就丢掉。
        for account in accounts(itemId: itemId, context: context) {
            context.delete(account)
        }
        try context.save()
    }

    /// 把一个账户**只**从本地移除：从列表消失、停止同步。
    ///
    /// ⚠️ 这**不是**撤销银行授权。Plaid 的 `/item/remove` 是 item 粒度的，
    /// 官方没有「移除单个 account」的接口 —— 真正的单账户撤权只有
    /// Link update mode 一条路（`createUpdateLinkToken` / `reconcileAccounts`）。
    /// 调用方不得把这个动作向用户描述成「已撤销授权」。
    ///
    /// 同步引擎只读本地记录、从不重建，所以删掉就不会自己回来；
    /// 但用户重走一遍绑定或「管理已连接的账户」时它会被重新建出来 ——
    /// 那时 Plaid 仍然在共享它，重新出现才是诚实的。
    ///
    /// **交易记录一律保留** —— 那些消费真实发生过。
    func removeLocally(account: LinkedBankAccount, context: ModelContext) {
        context.delete(account)
        try? context.save()
    }

    /// 清空本地全部绑定记录。
    ///
    /// 只在**账号已被删除**之后调用 —— 那时后端的 linked_item 已经连同用户一起没了，
    /// 本地这份镜像再留着就是一堆指向不存在 item 的僵尸记录，
    /// 用户点解绑只会一直收到 404。
    ///
    /// **不删交易记录**：那些消费真实发生过，用户的返现统计也建立在它们之上。
    func clearAllLocalBindings(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<LinkedBankAccount>())) ?? []
        for account in all {
            context.delete(account)
        }
        try? context.save()
        print("ℹ️ 账号已删除，清理了 \(all.count) 条本地绑定记录（交易记录保留）")
    }

    // MARK: - 查询

    func listItems() async throws -> [LinkedItemDTO] {
        try await api.get("/api/plaid/items")
    }

    /// 取某个 item 下的全部本地账户。
    /// 不是 private —— unlink 和 reconcile 都要用，测试也要用。
    func accounts(itemId: String, context: ModelContext) -> [LinkedBankAccount] {
        let descriptor = FetchDescriptor<LinkedBankAccount>(
            predicate: #Predicate { $0.itemId == itemId })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func findAccount(itemId: String,
                             accountId: String,
                             context: ModelContext) -> LinkedBankAccount? {
        let descriptor = FetchDescriptor<LinkedBankAccount>(
            predicate: #Predicate { $0.itemId == itemId && $0.accountId == accountId })
        return (try? context.fetch(descriptor))?.first
    }
}
