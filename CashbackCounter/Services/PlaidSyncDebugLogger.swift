//
//  PlaidSyncDebugLogger.swift
//  CashbackCounter
//
//  同步过程的控制台输出：拉回了什么、每一笔被怎么处理了。
//
//  ⚠️ **只在 DEBUG 构建里存在。** 这里打印的是完整的银行交易流水 ——
//  商户、金额、日期、账户尾号，是最敏感的一类个人信息。
//  release 构建里所有方法都是空实现，编译器会整个优化掉，
//  不存在"忘了关日志开关"导致真实用户的流水进系统日志的可能。
//
//  写法沿用 StatementDebugLogger 的约定：DEBUG 下有实现、release 下留同名空方法，
//  这样调用点不需要到处写 #if。
//

import Foundation

enum PlaidSyncDebugLogger {

    #if DEBUG

    /// 临时想安静一会儿时可以关掉，不影响 release
    static var isEnabled = true

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - 拉取

    static func windowFetched(itemId: String,
                              start: Date,
                              end: Date,
                              count: Int,
                              truncated: Bool) {
        guard isEnabled else { return }
        print("""

            ┌─ [PlaidSync] 拉取窗口 \(dateFormatter.string(from: start)) ~ \(dateFormatter.string(from: end))
            │  item=\(itemId)
            │  返回 \(count) 笔\(truncated ? "（已达上限，将切小窗口重拉）" : "")
            └─
            """)
    }

    /// 把服务端返回的**每一笔原始数据**全字段打出来。
    ///
    /// 这是"所有信息"的字面意思：过滤和判断之前的样子。
    /// 之后每笔还会有一行处理结论，两者对照着看就能定位任何一笔为什么没进来。
    static func dumpFetched(_ transactions: [PlaidTransactionDTO], itemId: String) {
        guard isEnabled else { return }

        print("\n===== [PlaidSync] item=\(itemId) 共拉回 \(transactions.count) 笔原始交易 =====")
        for (index, t) in transactions.enumerated() {
            print("""
                [\(index + 1)/\(transactions.count)]
                  accountId       : \(t.accountId)
                  accountName     : \(t.accountName ?? "nil")
                  accountMask     : \(t.accountMask ?? "nil")
                  date            : \(t.date)
                  name            : \(t.name ?? "nil")
                  merchantName    : \(t.merchantName ?? "nil")
                  amount          : \(t.amount)   \(t.amount < 0 ? "(负数=资金流入)" : "(正数=资金流出)")
                  currency        : \(t.currency ?? "nil")
                  pending         : \(t.pending)
                  category        : \(t.category ?? "nil")
                  categoryDetailed: \(t.categoryDetailed ?? "nil")
                  paymentChannel  : \(t.paymentChannel ?? "nil")
                """)
        }
        print("===== 原始数据结束 =====\n")
    }

    // MARK: - 处理结论

    /// 每一笔的处理结论。和上面的原始数据一一对应。
    ///
    /// **分类一定要打出来**，而且要打 detailed：判定几乎全是按分类做的，
    /// 少了它这一行只告诉你"结果是什么"，不告诉你"凭什么" ——
    /// 而你想查的恰恰是后者。
    static func decision(_ transaction: PlaidTransactionDTO, verdict: String, detail: String? = nil) {
        guard isEnabled else { return }
        let merchant = transaction.resolvedMerchant
        let category = transaction.categoryDetailed ?? transaction.category ?? "无分类"
        let suffix = detail.map { " —— \($0)" } ?? ""
        print("  · \(transaction.date)  \(pad(merchant, 24))  \(padLeft(String(format: "%.2f", transaction.amount), 10))"
              + "  [\(pad(category, 42))]  →  \(verdict)\(suffix)")
    }

    static func processingHeader(_ count: Int) {
        guard isEnabled else { return }
        print("----- [PlaidSync] 逐笔处理（共 \(count) 笔）-----")
    }

    static func summary(itemId: String, text: String) {
        guard isEnabled else { return }
        print("----- [PlaidSync] item=\(itemId) 处理完毕：\(text) -----\n")
    }

    // MARK: - 排版

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
    }

    private static func padLeft(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    #else

    // release 下的空实现：调用点不用写 #if，而真实用户的流水永远不会进日志

    static var isEnabled: Bool { false }

    static func windowFetched(itemId: String, start: Date, end: Date, count: Int, truncated: Bool) {}

    static func dumpFetched(_ transactions: [PlaidTransactionDTO], itemId: String) {}

    static func decision(_ transaction: PlaidTransactionDTO, verdict: String, detail: String? = nil) {}

    static func processingHeader(_ count: Int) {}

    static func summary(itemId: String, text: String) {}

    #endif
}
