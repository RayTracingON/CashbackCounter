//
//  PlaidLinkSheet.swift
//  CashbackCounter
//
//  LinkKit 的唯一接触面。
//
//  单独成一个文件不是为了整齐，是为了**把 `import LinkKit` 关在这里** ——
//  LinkKit 导出了一个自己的 `Environment` 类型（Plaid 的 sandbox/production 枚举），
//  它会和 SwiftUI 的 `@Environment` 属性包装器撞名，导致同一个文件里
//  每一处 `@Environment(\.modelContext)` 都报 "ambiguous for type lookup"。
//  把 import 限制在这个文件里，其它视图就永远不会碰到这个坑。
//
//  对外只暴露一个纯 Swift 的回调，不泄漏任何 LinkKit 类型。
//

import LinkKit
import SwiftUI

struct PlaidLinkSheet: View {

    let linkToken: String

    /// 用户成功绑定。institutionName 来自 Link 的 metadata，
    /// 比绑定后再调一次 /items 去查要快一步，也少一次网络往返。
    let onSuccess: (_ publicToken: String, _ institutionName: String) -> Void

    /// 用户中途退出。error 为 nil 表示主动取消 —— **那不是错误，不要弹提示**
    let onExit: (_ errorMessage: String?) -> Void

    var body: some View {
        PlaidLinkView(token: linkToken) { success in
            onSuccess(success.publicToken, success.metadata.institution.name)
        } onExit: { exit in
            onExit(exit.error.map { $0.displayMessage ?? $0.localizedDescription })
        } onEvent: { _ in
            // Link 流程里的细粒度事件（选了哪家银行、卡在哪一步）。
            // 现在不需要，将来要做绑定漏斗分析时从这里取。
        } errorView: { error in
            // 只有 link_token 本身有问题才会走到这里（过期、环境不匹配）
            VStack(spacing: 12) {
                Text("无法打开 Plaid Link")
                    .font(.headline)
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("关闭") { onExit(error.localizedDescription) }
            }
            .padding()
        }
    }
}
