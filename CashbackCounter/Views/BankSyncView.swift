//
//  BankSyncView.swift
//  CashbackCounter
//
//  「银行同步」管理页：绑了哪些银行、哪些卡在同步、上次同步到什么时候。
//
//  这里也是整个银行同步功能唯一的入口 —— 拦截（未登录 / 阶段 4 的付费墙）
//  都做在这一页的动作上，而不是把入口藏起来。用户看得见功能存在才谈得上用它。
//

// ⚠️ 有意不 import LinkKit：它导出的 Environment 类型会和 SwiftUI 的
// @Environment 撞名。所有 LinkKit 相关的东西都封在 PlaidLinkSheet 里。
import SwiftData
import SwiftUI

/// 一次银行绑定（Plaid 的 item）在列表里的一个分组。
struct BankAccountGroup: Identifiable {

    /// 分组键就是 itemId —— 解绑和账户管理都是**按 item** 发起的
    let itemId: String

    /// section header 文案。同一家银行有多个 item 时会带上尾号区分
    let title: String

    let accounts: [LinkedBankAccount]

    var id: String { itemId }
}

/// 按 itemId 分组，**不是**按 institutionName。
///
/// 按银行名分组是个会静默删错东西的 bug：`completeLink` 的去重键是
/// `(itemId, accountId)`，同一家银行重走一遍 Link 会拿到**新的 itemId**
/// （个人号 + 商务号、断连后重绑都会），两个 item 因为名字一样被塞进同一个
/// section，而解绑按钮取的是 `accounts.first?.itemId` —— 到底解掉哪一个
/// 取决于排序，用户看到的「将撤销这家银行的授权」在那时是假的。
///
/// update mode 更是必须按 item 发起：UI 层指不准 item，整个功能就没有正确的入口。
///
/// 抽成自由函数是为了能测 —— View 里的 private 计算属性测不到，
/// 而这条逻辑值一个回归用例。
func groupAccountsByItem(_ accounts: [LinkedBankAccount]) -> [BankAccountGroup] {
    let byItem = Dictionary(grouping: accounts, by: \.itemId)

    // 同一个银行名落在几个 item 上？只有 >1 时才需要在 header 上加尾号，
    // 否则每个 section 都挂一串尾号只是噪音。
    var itemCountByInstitution: [String: Int] = [:]
    for group in byItem.values {
        guard let name = group.first?.institutionName else { continue }
        itemCountByInstitution[name, default: 0] += 1
    }

    return byItem.map { itemId, accounts -> BankAccountGroup in
        let institution = accounts.first?.institutionName ?? ""
        let masks = accounts.map(\.mask).filter { !$0.isEmpty }

        let needsDisambiguation = (itemCountByInstitution[institution] ?? 0) > 1
        let title = (needsDisambiguation && !masks.isEmpty)
            ? "\(institution) " + masks.map { "···\($0)" }.joined(separator: ", ")
            : institution

        return BankAccountGroup(itemId: itemId, title: title, accounts: accounts)
    }
    // 排序必须是确定的：Dictionary 的遍历顺序每次运行都可能不同，
    // 不排的话 section 会在每次刷新时跳来跳去。itemId 作为最后的决胜键，
    // 保证两个 item 连 title 都一样时顺序也稳定。
    .sorted { ($0.title, $0.itemId) < ($1.title, $1.itemId) }
}

struct BankSyncView: View {

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\LinkedBankAccount.institutionName),
                  SortDescriptor(\LinkedBankAccount.accountName)])
    private var accounts: [LinkedBankAccount]
    @Query private var cards: [CreditCard]

    @State private var auth = AuthService.shared
    @State private var linkService = PlaidLinkService.shared
    @State private var syncService = PlaidSyncService.shared
    @State private var subscriptions = SubscriptionManager.shared
    @State private var showPaywall = false

    @State private var pendingLink: PendingLink?
    @State private var isPreparingLink = false

    @State private var pendingMatch: PendingMatch?
    @State private var banner: Banner?
    @State private var itemPendingUnlink: String?
    /// reconcile 后 Plaid 一个账户都没返回的 item —— 等用户确认要不要整个解绑
    @State private var itemPendingZombieCleanup: String?
    /// 左滑待删除的那张卡
    @State private var accountPendingDelete: PendingDelete?
    @State private var showSignIn = false
    /// 登录成功后要不要顺势进入绑定流程。
    /// 只有"点了绑定银行才被要求登录"的路径为 true —— 从页面上的登录引导进来的
    /// 用户只是想登录，不该被直接甩进 Plaid 弹窗。
    @State private var startLinkAfterSignIn = false

    /// 唤起 Link 弹窗的两种目的。
    ///
    /// **必须区分**：update mode 成功后绝不能走 `finishLink` —— 它会调
    /// `/api/plaid/exchange`，那会换出一个新的 itemId，同一家银行凭空多一份
    /// 绑定并开始重复计费。
    private enum LinkMode: Equatable {
        /// 新绑定，收尾走 completeLink
        case create
        /// 账户选择（update mode），收尾走 reconcileAccounts
        case update(itemId: String)
    }

    private struct PendingLink: Identifiable {
        let id = UUID()
        let token: String
        let mode: LinkMode
    }

    /// 左滑删除的目标。
    ///
    /// `isLastInItem` 决定这次删除到底是什么语义 —— 这是整个交互唯一的分岔：
    /// Plaid 的 `/item/remove` 是 **item 粒度**的，没有「移除单个 account」的接口。
    /// 所以只有「这个 item 下就剩这一张卡」时，删除才谈得上真的向银行撤权；
    /// 其余情况只能本地移除，**文案上不能谎称已撤销授权**。
    private struct PendingDelete: Identifiable {
        let id = UUID()
        let account: LinkedBankAccount
        let isLastInItem: Bool
    }

    /// 需要用户手动指定卡片的账户
    private struct PendingMatch: Identifiable {
        let id = UUID()
        let account: LinkedBankAccount
        let candidates: [CreditCard]
        /// 空 = 卡包里没有同尾号的卡，让用户从全部卡里挑
        var isAmbiguous: Bool { !candidates.isEmpty }
    }

    private struct Banner: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// 按 item 分组。逻辑在 `groupAccountsByItem`，这里只是接线
    private var grouped: [BankAccountGroup] {
        groupAccountsByItem(accounts)
    }

    var body: some View {
        List {
            // 未登录时整页只有登录引导 —— 绑定银行必须先有账号，
            // 因为后端是按 userId 存 access_token 的，没有身份就无处安放这段绑定关系。
            if !auth.isSignedIn {
                signInPrompt
            } else if accounts.isEmpty {
                emptyState
            } else {
                ForEach(grouped) { group in
                    Section {
                        ForEach(group.accounts) { account in
                            accountRow(account)
                                // allowsFullSwipe: false —— 一滑到底就执行太容易误触，
                                // 而这个动作在「最后一张卡」时会连带撤销整家银行的授权。
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("删除", role: .destructive) {
                                        accountPendingDelete = PendingDelete(
                                            account: account,
                                            isLastInItem: group.accounts.count == 1)
                                    }
                                }
                        }
                    } header: {
                        Text(group.title)
                    } footer: {
                        groupActions(for: group)
                    }
                }
            }

            if auth.isSignedIn {
                Section {
                    Button {
                        Task { await startLink() }
                    } label: {
                        Label(accounts.isEmpty ? "绑定银行" : "添加银行", systemImage: "plus.circle")
                    }
                    .disabled(isPreparingLink || syncService.isSyncing)
                } footer: {
                    Text("绑定前需要用 \(BiometricGate.methodName) 验证身份。\n\n可以绑定信用卡，也可以绑定活期/储蓄账户（借记卡消费同样会算返现）。\n房贷、证券、定存这类没有日常消费的账户不在范围内。\n\n我们拿不到完整卡号 —— Plaid 的任何产品都不提供。")
                }
            }
        }
        .navigationTitle("银行同步")
        .navigationBarTitleDisplayMode(.inline)
        // 下拉刷新 = 手动触发一次增量同步。
        // 阶段 6 的静默推送是"尽力而为"的，不保证送达，
        // 所以手动刷新不是锦上添花，是方案成立的另一半。
        .refreshable { await syncNow() }
        .overlay { syncOverlay }
        .sheet(item: $pendingLink) { pending in linkSheet(pending) }
        .sheet(isPresented: $showSignIn) {
            SignInView {
                guard startLinkAfterSignIn else { return }
                startLinkAfterSignIn = false
                Task { await startLink() }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView { Task { await startLink() } }
        }
        .sheet(item: $pendingMatch) { pending in
            CardPickerSheet(
                account: pending.account,
                candidates: pending.isAmbiguous ? pending.candidates : cards,
                isAmbiguous: pending.isAmbiguous) { card in
                    linkService.assign(card: card, to: pending.account, context: context)
                    pendingMatch = nil
                }
        }
        .alert(item: $banner) { banner in
            Alert(title: Text(banner.title),
                  message: Text(banner.message),
                  dismissButton: .cancel(Text("好")))
        }
        .confirmationDialog(
            "解绑这家银行？",
            isPresented: Binding(
                get: { itemPendingUnlink != nil },
                set: { if !$0 { itemPendingUnlink = nil } }),
            titleVisibility: .visible,
            presenting: itemPendingUnlink
        ) { itemId in
            Button("解绑", role: .destructive) { Task { await unlink(itemId: itemId) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("将撤销这次绑定的授权，之后不再自动同步。\n\n同一家银行的其它绑定不受影响。已经导入的交易记录会全部保留。")
        }
        // Plaid 一个账户都没返回时走这里 —— 本地记录此刻**一条都没动**，
        // 由用户决定要不要整个解绑。不问就删是不可逆的。
        .confirmationDialog(
            "这次绑定已无共享账户",
            isPresented: Binding(
                get: { itemPendingZombieCleanup != nil },
                set: { if !$0 { itemPendingZombieCleanup = nil } }),
            titleVisibility: .visible,
            presenting: itemPendingZombieCleanup
        ) { itemId in
            Button("解除绑定", role: .destructive) {
                Task {
                    await unlink(
                        itemId: itemId,
                        successMessage: String.loc("这次绑定已经没有共享账户，已一并解除。已导入的交易记录全部保留。"))
                }
            }
            Button("保留", role: .cancel) {}
        } message: { _ in
            Text("Plaid 没有返回任何账户。\n\n不解除的话这次绑定会一直留在这里但不再同步，而且没有任何账户可管理。")
        }
        // 左滑删除的确认。两种语义差别很大，所以按钮和说明都随情况变。
        .confirmationDialog(
            "删除这张卡？",
            isPresented: Binding(
                get: { accountPendingDelete != nil },
                set: { if !$0 { accountPendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: accountPendingDelete
        ) { pending in
            Button(pending.isLastInItem
                   ? String.loc("删除并撤销银行授权")
                   : String.loc("仅从 App 移除"),
                   role: .destructive) {
                Task { await deleteAccount(pending) }
            }
            Button("取消", role: .cancel) {}
        } message: { pending in
            Text(pending.isLastInItem
                 ? "这是这次绑定下最后一张卡。删除会同时向银行撤销这次绑定的授权，之后不再自动同步。\n\n已经导入的交易记录会全部保留。"
                 : "Plaid 不支持单独撤销一个账户的授权 —— 只能整次绑定一起撤。\n\n这里只会把它从 App 移除并停止同步，银行授权仍然有效。要真正撤销，用下面的「管理已连接的账户」。\n\n已经导入的交易记录会全部保留。")
        }
    }

    // MARK: - 子视图

    /// 未登录时的整页引导。
    ///
    /// 这里是硬性前置，不是"稍后再说"：绑定关系在后端是挂在 userId 名下的，
    /// 没有账号就没有地方存 access_token，也没法在换设备后找回已绑的银行。
    private var signInPrompt: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                Text("需要先登录")
                    .font(.headline)

                Text("绑定的银行是记在你账号名下的 —— 登录之后才能保存这段授权，换设备时也能找回。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    startLinkAfterSignIn = false
                    showSignIn = true
                } label: {
                    Label("使用 Apple ID 登录", systemImage: "apple.logo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        .listRowBackground(Color.clear)
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "building.columns")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("还没有绑定银行")
                    .font(.headline)
                Text("绑定后，信用卡消费会自动同步进来，并按你设置的费率算返现和积分。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        .listRowBackground(Color.clear)
    }

    private func accountRow(_ account: LinkedBankAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayTitle)
                        .font(.body)

                    if let card = account.card {
                        Text("已关联「\(card.bankName) \(card.endNum)」")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未关联卡片 —— 无法计算奖励")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { account.syncEnabled },
                    set: { account.syncEnabled = $0; try? context.save() }))
                    .labelsHidden()
                    // 没关联卡片就不允许打开：没有卡就没有费率，算不了奖励。
                    // 做成禁用而不是允许打开后静默不同步 —— 后者用户会以为坏了。
                    .disabled(account.card == nil)
            }

            HStack(spacing: 12) {
                if account.card == nil {
                    Button("指定卡片") {
                        pendingMatch = PendingMatch(
                            account: account,
                            candidates: cards.filter { $0.endNum == account.mask })
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }

                if let last = account.lastSyncedAt {
                    Text("上次同步 \(last.formatted(.relative(presentation: .named).locale(AppLanguage.locale)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if account.syncEnabled {
                    Text("尚未同步")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// section footer 的两个动作。
    ///
    /// 「管理已连接的账户」是**单独摘掉一张卡**的唯一入口 —— Plaid 的解绑接口
    /// 是 item 粒度的，一次绑定下面有多张卡时它只能全解。
    private func groupActions(for group: BankAccountGroup) -> some View {
        HStack {
            Button("管理已连接的账户") {
                Task { await startAccountSelection(itemId: group.itemId) }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .disabled(isPreparingLink || syncService.isSyncing)

            Spacer()

            Button("解绑 \(group.title)", role: .destructive) {
                itemPendingUnlink = group.itemId
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var syncOverlay: some View {
        if syncService.isSyncing {
            VStack(spacing: 10) {
                ProgressView()
                if let message = syncService.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// PlaidLinkSheet 对模式无感知 —— 它只收一个 token。
    /// 分流在这里：走错分支的代价是凭空多一个 item（见 LinkMode 的注释）。
    private func linkSheet(_ pending: PendingLink) -> some View {
        PlaidLinkSheet(linkToken: pending.token) { publicToken, institutionName in
            pendingLink = nil
            switch pending.mode {
            case .create:
                Task {
                    await finishLink(publicToken: publicToken, institutionName: institutionName)
                }
            case .update(let itemId):
                // update mode 下 publicToken 和 institutionName 直接丢弃：
                // access_token 没变、itemId 已知，**再 exchange 一次就是多一个 item**。
                Task { await finishAccountSelection(itemId: itemId) }
            }
        } onExit: { errorMessage in
            pendingLink = nil
            // 用户主动退出不是错误，只有真的报错才提示
            if let errorMessage {
                banner = Banner(title: String.loc("绑定未完成"), message: errorMessage)
            }
        }
    }

    // MARK: - 动作

    private func startLink() async {
        // 整页已经拦过一次，这里是第二道 —— 绑定是要在后端落 access_token 的动作，
        // 不能只依赖 UI 层挡住。
        guard auth.isSignedIn else {
            startLinkAfterSignIn = true
            showSignIn = true
            return
        }

        // 付费墙拦在**发起动作处**，不是藏入口。
        // 后端那边 link-token / exchange 也会各自校验一次订阅 ——
        // 这里挡住只是为了给用户一个体面的界面，真正的闸门在服务端。
        guard subscriptions.isPremium else {
            showPaywall = true
            return
        }

        // 唤起 Link 之前的生物识别关卡。
        //
        // 放在申请 link_token **之前**：验证没过就不该消耗一个 token，
        // 也不该让任何请求打到后端。
        switch await BiometricGate.authenticate(reason: String.loc("验证身份后连接银行账户")) {
        case .success:
            break
        case .canceled:
            // 用户主动取消不是错误，安静退出
            return
        case .unavailable(let message):
            banner = Banner(title: "无法验证身份", message: message)
            return
        case .failed(let message):
            banner = Banner(title: "身份验证失败", message: message)
            return
        }

        isPreparingLink = true
        defer { isPreparingLink = false }

        do {
            let token = try await linkService.createLinkToken()
            pendingLink = PendingLink(token: token, mode: .create)
        } catch {
            banner = Banner(title: String.loc("无法开始绑定"), message: error.localizedDescription)
        }
    }

    /// 「管理已连接的账户」：把用户送进 Plaid 的账户选择页（Link update mode）。
    private func startAccountSelection(itemId: String) async {
        guard auth.isSignedIn else {
            startLinkAfterSignIn = false
            showSignIn = true
            return
        }

        // ⚠️ **有意不加付费墙**（后端那个端点也刻意没拦）：
        // update mode 是让用户**减少**共享范围的动作。订阅过期就撤销不了银行
        // 授权，那是合规和信任问题，不是可以拿来做转化的杠杆。
        // 这条别顺手对齐 startLink，改之前先和仓库所有者确认。

        // 生物识别照加：改的是银行授权范围，和 startLink 同级。
        // 放在申请 token **之前** —— 没验过就不该有任何请求打到后端。
        switch await BiometricGate.authenticate(reason: String.loc("验证身份后管理已连接的账户")) {
        case .success:
            break
        case .canceled:
            return
        case .unavailable(let message):
            banner = Banner(title: "无法验证身份", message: message)
            return
        case .failed(let message):
            banner = Banner(title: "身份验证失败", message: message)
            return
        }

        isPreparingLink = true
        defer { isPreparingLink = false }

        do {
            let token = try await linkService.createUpdateLinkToken(itemId: itemId)
            pendingLink = PendingLink(token: token, mode: .update(itemId: itemId))
        } catch {
            banner = Banner(title: String.loc("无法开始管理账户"),
                            message: error.localizedDescription)
        }
    }

    /// update mode 结束后的收尾：**不 exchange**，只把本地列表对齐到 Plaid。
    private func finishAccountSelection(itemId: String) async {
        do {
            switch try await linkService.reconcileAccounts(itemId: itemId, context: context) {
            case .aligned(let removed, let added):
                let message: String
                switch (removed, added) {
                case (0, 0):
                    // 这句最容易误导：很多银行（OAuth 机构）的账户共享范围由银行自己的
                    // 页面控制，Plaid 不显示自家的勾选页。用户在那边只是重新登录、
                    // 没改共享范围的话，回到这里确实什么都没变 —— 得说清楚原因。
                    message = String.loc("账户列表没有变化。\n\n如果刚才跳转到了银行自己的页面：这类银行的账户共享范围由银行控制，需要在那个页面上取消勾选要移除的卡，回到这里才会生效。")
                case (_, 0):
                    message = String.loc("已移除 \(removed) 个账户")
                case (0, _):
                    message = String.loc("新增 \(added) 个账户")
                default:
                    message = String.loc("已移除 \(removed) 个账户，新增 \(added) 个")
                }
                banner = Banner(title: String.loc("账户已更新"), message: message)

            case .noRemoteAccounts:
                // 本地此刻一条都没删 —— 交给用户决定要不要整个解绑，
                // 免得留下一个 App 里点不到、Plaid 那边还在计费的僵尸 item。
                itemPendingZombieCleanup = itemId
            }
        } catch {
            // 失败时本地记录原样保留。这条提示要说清楚「什么都没变」，
            // 否则用户会以为自己刚才的勾选生效了。
            banner = Banner(
                title: String.loc("账户列表更新失败"),
                message: String.loc("本地账户列表未做任何改动，可以稍后重试。\n\n\(error.localizedDescription)"))
        }
    }

    private func finishLink(publicToken: String, institutionName: String) async {
        do {
            let result = try await linkService.completeLink(
                publicToken: publicToken,
                institutionName: institutionName,
                context: context)

            // 有歧义的账户优先弹选择器，让用户当场解决
            if let ambiguous = result.matches.compactMap({ match -> PendingMatch? in
                if case .ambiguous(let account, let candidates) = match {
                    return PendingMatch(account: account, candidates: candidates)
                }
                return nil
            }).first {
                pendingMatch = ambiguous
            }

            let unmatched = result.matches.filter {
                if case .unmatched = $0 { return true }
                return false
            }
            if !unmatched.isEmpty {
                let masks = unmatched.compactMap { match -> String? in
                    if case .unmatched(let account) = match { return account.mask }
                    return nil
                }.joined(separator: "、")
                banner = Banner(
                    title: String.loc("有账户未匹配到卡片"),
                    message: String.loc("卡包里没有尾号 \(masks) 的卡。可以先去「卡包」建卡，再回来点「指定卡片」。未关联卡片的账户不会同步。"))
            }

            // 首次全量。刚绑完 Plaid 还在向银行拉数据，
            // 这里会自动等 PRODUCT_NOT_READY 过去。
            try await syncService.performInitialSyncWaitingForData(
                itemId: result.itemId, context: context)

        } catch {
            banner = Banner(title: String.loc("绑定后处理失败"), message: error.localizedDescription)
        }
    }

    private func syncNow() async {
        guard auth.isSignedIn else { return }

        let result = await syncService.syncAll(context: context)
        if !result.errors.isEmpty {
            banner = Banner(title: String.loc("同步未完全成功"),
                            message: result.errors.joined(separator: "\n"))
        }
    }

    /// 左滑删除某一张卡。
    ///
    /// ⚠️ Plaid **没有**「移除单个 account」的接口，`/item/remove` 是 item 粒度的。
    /// 所以只有一种情况能真正向 Plaid 撤权：这个 item 下已经只剩这一张卡。
    /// 其余情况只能做本地移除 —— 那时**不能**在文案上说「已撤销授权」，
    /// 说了就是在用户的隐私预期上撒谎。
    private func deleteAccount(_ pending: PendingDelete) async {
        // 先取出来：走 unlink 那条路时这个对象会被删掉
        let itemId = pending.account.itemId

        if pending.isLastInItem {
            // 唯一能真撤的情况。后端保证顺序：先调 Plaid /item/remove，
            // 成功了才删自己的记录。
            await unlink(
                itemId: itemId,
                successMessage: String.loc("已向银行撤销这次绑定的授权。已导入的交易记录全部保留。"))
            return
        }

        linkService.removeLocally(account: pending.account, context: context)
        banner = Banner(
            title: String.loc("已从 App 移除"),
            message: String.loc("这张卡不再显示，也不再同步。\n\n银行授权仍然有效 —— Plaid 不支持单独撤销一个账户。要真正撤销，用「管理已连接的账户」在银行页面取消勾选。"))
    }

    private func unlink(itemId: String, successMessage: String? = nil) async {
        do {
            try await linkService.unlink(itemId: itemId, context: context)
            if let successMessage {
                banner = Banner(title: String.loc("已解除绑定"), message: successMessage)
            }
        } catch {
            banner = Banner(title: String.loc("解绑失败"), message: error.localizedDescription)
        }
    }
}

// MARK: - 卡片选择器

private struct CardPickerSheet: View {

    let account: LinkedBankAccount
    let candidates: [CreditCard]
    let isAmbiguous: Bool
    let onPick: (CreditCard) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { card in
                        Button {
                            onPick(card)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(card.bankName) \(card.type)")
                                    Text("尾号 \(card.endNum)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if card.endNum == account.mask {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text(account.displayTitle)
                } footer: {
                    Text(isAmbiguous
                         ? "卡包里有多张尾号 \(account.mask) 的卡，选错会把交易记到别的卡上、连费率和上限一起算错，所以需要你来确认。"
                         : "没有尾号 \(account.mask) 的卡。你可以先关联到任意一张卡，或者取消后去「卡包」新建。")
                }
            }
            .navigationTitle("选择卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
