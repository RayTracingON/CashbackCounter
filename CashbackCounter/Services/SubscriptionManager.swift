//
//  SubscriptionManager.swift
//  CashbackCounter
//
//  订阅状态的唯一出口。全 App 判断"是不是会员"只看 isPremium。
//
//  和路线图原方案的区别：**后端也要知道订阅状态**。
//  原因是路线图自己记着的那笔账 —— Plaid 按活跃 item 每月计费，
//  后端不知道订阅状态的话，用户过期甚至删了 App，item 仍在烧钱。
//
//  所以这里除了本地判断，还要把 **Apple 签名的交易（JWS）** 上报给后端。
//  注意上报的不是"我说我订阅了"，而是 Apple 签过名的凭据，后端用 Apple 根证书验签 ——
//  伪造需要 Apple 的私钥。这也是后端敢据此放行的原因。
//

import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class SubscriptionManager {

    static let shared = SubscriptionManager()

    // MARK: - 产品

    enum Plan: String, CaseIterable {
        case monthly = "com.junhaohuang.CashbackCounter.premium.monthly"
        case yearly = "com.junhaohuang.CashbackCounter.premium.yearly"
    }

    // MARK: - 对外状态

    /// **全 App 唯一的会员判断出口。** 别在别处自己算。
    ///
    /// 本地 StoreKit 权益**或**后端认定有效，两者取或。
    ///
    /// 为什么要认后端：有几种合法的付费方式不会出现在本机的
    /// `Transaction.currentEntitlements` 里 —— 推广代码兑换、家庭共享、
    /// 以及运营侧手工开通（比如开发者自己的账号）。
    /// 只认本地的话，这些人明明有权益却被付费墙挡着。
    ///
    /// 反过来只认后端也不行：后端不可达时用户会突然失去已付费的功能。
    /// 取或之后，任一侧认可就放行，两边都不可用才拦。
    var isPremium: Bool { localEntitlementActive || backendReportedActive }

    /// 本机 StoreKit 的权益
    private(set) var localEntitlementActive = false
    /// 后端认定的订阅状态（含手工开通、兑换码等本地看不到的来源）
    private(set) var backendReportedActive = false

    private(set) var products: [Product] = []
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false

    /// 各产品的介绍性优惠资格，productID -> 是否合格。
    ///
    /// 单独缓存是因为 `isEligibleForIntroOffer` 是 async 的，View 的 body 里读不了。
    private(set) var introOfferEligible: [String: Bool] = [:]

    /// 当前订阅的到期时刻，用于设置页展示
    private(set) var expiresAt: Date?

    private let api = PlaidAPIClient.shared

    /// 长驻监听 Transaction.updates。续订、退款、家庭共享变更都从这里来 ——
    /// 它们**不经过 purchase() 的返回值**，只在这个流里出现。
    private var updatesTask: Task<Void, Never>?

    private init() {}

    // MARK: - 生命周期

    /// App 启动时调用一次
    func start() {
        // 监听要在任何 await 之前挂上：purchase() 之外的交易（续订、
        // 别的设备上的购买、退款）只会从这个流里来，漏掉就永远收不到。
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                await self?.handle(updateResult: result)
            }
        }

        Task {
            await loadProducts()
            await refreshEntitlements()
            // refreshEntitlements 只在有本地交易时才问到后端；
            // 手工开通/兑换码的用户本地是空的，必须单独查一次
            await refreshBackendStatus()
        }
    }

    // 有意没有 deinit：这是个活到进程结束的单例，监听**本来就不该被取消** ——
    // 取消它意味着从此收不到续订和退款。
    // （另外 @MainActor 类的 deinit 是 nonisolated 的，那里也碰不到 updatesTask。）

    // MARK: - 产品

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let loaded = try await Product.products(for: Plan.allCases.map(\.rawValue))
            // 按价格排序，月付在前
            products = loaded.sorted { $0.price < $1.price }
        } catch {
            print("⚠️ 拉取订阅产品失败：\(error.localizedDescription)")
        }

        await refreshIntroOfferEligibility()
    }

    /// 刷新免费试用资格。
    ///
    /// 资格是**按订阅群组**算的，不是按产品：用户在月付上用掉试用之后，
    /// 年付也一并不再合格。所以这里每个产品都要单独问一次，
    /// 不能拿一个的结果套到另一个上。
    ///
    /// 购买、恢复、退款之后资格都会变，所以 `refreshEntitlements` 末尾也会调它。
    func refreshIntroOfferEligibility() async {
        var eligible: [String: Bool] = [:]
        for product in products {
            guard let subscription = product.subscription else { continue }
            eligible[product.id] = await subscription.isEligibleForIntroOffer
        }
        introOfferEligible = eligible
    }

    /// 这个产品现在能不能拿到免费试用。
    ///
    /// 三个条件缺一不可：产品配了介绍性优惠、该优惠是**免费**（而不是首期折扣）、
    /// 且当前 Apple ID 还合格。付费墙的文案只以这个为准 ——
    /// 承诺了试用却拿不到，是审核里最容易被拒的一类问题。
    func freeTrialPeriod(for product: Product) -> Product.SubscriptionPeriod? {
        guard introOfferEligible[product.id] == true,
              let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else {
            return nil
        }
        return offer.period
    }

    // MARK: - 购买

    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        isPurchasing = true
        defer { isPurchasing = false }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            // 只认通过校验的交易。unverified 意味着签名有问题，直接当没买过 ——
            // StoreKit 已经替我们做了本地验签，这一层不能跳过。
            guard case .verified(let transaction) = verification else {
                return false
            }
            await transaction.finish()
            await refreshEntitlements()
            return true

        case .userCancelled:
            return false

        case .pending:
            // 家长同意、待付款等。权益会在稍后通过 Transaction.updates 到达
            return false

        @unknown default:
            return false
        }
    }

    /// 恢复购买。**App Store 审核硬要求**：有订阅就必须提供恢复入口。
    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            print("⚠️ 恢复购买失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 权益

    /// 重新计算权益，并把签名交易上报后端。
    ///
    /// 启动、购买后、收到 Transaction.updates、登录成功后都要调。
    func refreshEntitlements() async {
        var active = false
        var latestExpiry: Date?
        var signedTransactions: [String] = []

        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Plan(rawValue: transaction.productID) != nil else {
                continue
            }

            // 退款/撤销的交易仍会出现在这里，必须自己排除
            if transaction.revocationDate != nil {
                continue
            }

            if let expiry = transaction.expirationDate, expiry > Date() {
                active = true
                if latestExpiry == nil || expiry > latestExpiry! {
                    latestExpiry = expiry
                }
            }

            // 后端要的是 Apple 签名的原始 JWS，不是我们解析后的结论
            signedTransactions.append(result.jwsRepresentation)
        }

        localEntitlementActive = active
        if let latestExpiry {
            expiresAt = latestExpiry
        }

        await syncToBackend(signedTransactions)

        // 买过就不再合格了，付费墙上的"免费试用"字样得跟着消失
        await refreshIntroOfferEligibility()
    }

    /// 单独拉一次后端状态。
    ///
    /// 必要性：用户完全没有本地交易时（手工开通、兑换码），
    /// `syncToBackend` 送上去的是空列表，后端只会回显当前状态而不会新增 ——
    /// 所以那条回显就是我们唯一能知道"其实已开通"的途径。
    func refreshBackendStatus() async {
        guard AuthService.shared.isSignedIn else {
            backendReportedActive = false
            return
        }

        do {
            let status: BackendSubscriptionStatus = try await api.get("/api/subscription/status")
            apply(status)
        } catch {
            // 拉不到就维持现状 —— 不能因为一次网络失败就把已付费用户降级
            print("⚠️ 查询后端订阅状态失败：\(error.localizedDescription)")
        }
    }

    private func apply(_ status: BackendSubscriptionStatus) {
        backendReportedActive = status.active
        if expiresAt == nil, let raw = status.expiresAt {
            expiresAt = ISO8601DateFormatter().date(from: raw)
        }
    }

    /// 把签名交易送给后端验签入库。
    ///
    /// 失败不影响本地权益 —— 用户已经付过钱，不能因为一次网络抖动就把功能锁上。
    /// 下次启动/回前台会再试。代价是后端的状态会短暂滞后。
    private func syncToBackend(_ signedTransactions: [String]) async {
        guard AuthService.shared.isSignedIn else { return }

        do {
            let status: BackendSubscriptionStatus = try await api.post(
                "/api/subscription/verify",
                body: VerifyRequest(signedTransactions: signedTransactions))
            apply(status)
            print("✅ 订阅状态已同步到后端：active=\(status.active), 到期=\(status.expiresAt ?? "-")")
        } catch {
            print("⚠️ 同步订阅状态到后端失败：\(error.localizedDescription)")
            // 上报失败不代表没订阅，单独再查一次后端的既有状态
            await refreshBackendStatus()
        }
    }

    private func handle(updateResult: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = updateResult else { return }
        await transaction.finish()
        await refreshEntitlements()
    }
}

// MARK: - 传输模型

private struct VerifyRequest: Encodable {
    let signedTransactions: [String]

    enum CodingKeys: String, CodingKey {
        case signedTransactions = "signed_transactions"
    }
}

private struct BackendSubscriptionStatus: Decodable {
    let active: Bool
    let productId: String?
    let expiresAt: String?
}
