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

struct BankSyncView: View {

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\LinkedBankAccount.institutionName),
                  SortDescriptor(\LinkedBankAccount.accountName)])
    private var accounts: [LinkedBankAccount]
    @Query private var cards: [CreditCard]

    @State private var auth = AuthService.shared
    @State private var linkService = PlaidLinkService.shared
    @State private var syncService = PlaidSyncService.shared

    @State private var linkToken: String?
    @State private var isPresentingLink = false
    @State private var isPreparingLink = false

    @State private var pendingMatch: PendingMatch?
    @State private var banner: Banner?
    @State private var itemPendingUnlink: String?
    @State private var showSignIn = false
    /// 登录成功后要不要顺势进入绑定流程。
    /// 只有"点了绑定银行才被要求登录"的路径为 true —— 从页面上的登录引导进来的
    /// 用户只是想登录，不该被直接甩进 Plaid 弹窗。
    @State private var startLinkAfterSignIn = false

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

    /// 按银行分组
    private var grouped: [(institution: String, accounts: [LinkedBankAccount])] {
        Dictionary(grouping: accounts, by: \.institutionName)
            .map { (institution: $0.key, accounts: $0.value) }
            .sorted { $0.institution < $1.institution }
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
                ForEach(grouped, id: \.institution) { group in
                    Section {
                        ForEach(group.accounts) { account in
                            accountRow(account)
                        }
                    } header: {
                        Text(group.institution)
                    } footer: {
                        unlinkButton(for: group)
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
        .sheet(isPresented: $isPresentingLink) { linkSheet }
        .sheet(isPresented: $showSignIn) {
            SignInView {
                guard startLinkAfterSignIn else { return }
                startLinkAfterSignIn = false
                Task { await startLink() }
            }
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
            Text("将撤销这家银行的授权，之后不再自动同步。\n\n已经导入的交易记录会全部保留。")
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
                    Text("上次同步 \(last.formatted(.relative(presentation: .named)))")
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

    private func unlinkButton(for group: (institution: String, accounts: [LinkedBankAccount])) -> some View {
        HStack {
            Spacer()
            Button("解绑 \(group.institution)", role: .destructive) {
                itemPendingUnlink = group.accounts.first?.itemId
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

    @ViewBuilder
    private var linkSheet: some View {
        if let linkToken {
            PlaidLinkSheet(linkToken: linkToken) { publicToken, institutionName in
                isPresentingLink = false
                Task {
                    await finishLink(publicToken: publicToken, institutionName: institutionName)
                }
            } onExit: { errorMessage in
                isPresentingLink = false
                // 用户主动退出不是错误，只有真的报错才提示
                if let errorMessage {
                    banner = Banner(title: "绑定未完成", message: errorMessage)
                }
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

        // 唤起 Link 之前的生物识别关卡。
        //
        // 放在申请 link_token **之前**：验证没过就不该消耗一个 token，
        // 也不该让任何请求打到后端。
        switch await BiometricGate.authenticate(reason: "验证身份后连接银行账户") {
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
            linkToken = try await linkService.createLinkToken()
            isPresentingLink = true
        } catch {
            banner = Banner(title: "无法开始绑定", message: error.localizedDescription)
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
                    title: "有账户未匹配到卡片",
                    message: "卡包里没有尾号 \(masks) 的卡。可以先去「卡包」建卡，再回来点「指定卡片」。未关联卡片的账户不会同步。")
            }

            // 首次全量。刚绑完 Plaid 还在向银行拉数据，
            // 这里会自动等 PRODUCT_NOT_READY 过去。
            try await syncService.performInitialSyncWaitingForData(
                itemId: result.itemId, context: context)

        } catch {
            banner = Banner(title: "绑定后处理失败", message: error.localizedDescription)
        }
    }

    private func syncNow() async {
        guard auth.isSignedIn else { return }

        let result = await syncService.syncAll(context: context)
        if !result.errors.isEmpty {
            banner = Banner(title: "同步未完全成功",
                            message: result.errors.joined(separator: "\n"))
        }
    }

    private func unlink(itemId: String) async {
        do {
            try await linkService.unlink(itemId: itemId, context: context)
        } catch {
            banner = Banner(title: "解绑失败", message: error.localizedDescription)
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
