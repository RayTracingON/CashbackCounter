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
                accountName: dto.name ?? dto.officialName ?? "信用卡",
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

    // MARK: - 解绑

    /// 解绑一家银行。
    ///
    /// 后端保证正确的顺序：先调 Plaid `/item/remove` 撤销授权，成功后才删自己的记录。
    /// 所以这里等它成功了再删本地的 LinkedBankAccount。
    ///
    /// **已导入的交易一律保留** —— 历史账目不该因为解绑而消失，
    /// 那些消费是真实发生过的，用户的返现统计也建立在它们之上。
    func unlink(itemId: String, context: ModelContext) async throws {
        let _: UnlinkResponse = try await api.post(
            "/api/plaid/unlink",
            query: [URLQueryItem(name: "itemId", value: itemId)])

        for account in accounts(itemId: itemId, context: context) {
            context.delete(account)
        }
        try context.save()
    }

    // MARK: - 查询

    func listItems() async throws -> [LinkedItemDTO] {
        try await api.get("/api/plaid/items")
    }

    private func accounts(itemId: String, context: ModelContext) -> [LinkedBankAccount] {
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
