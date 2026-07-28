//
//  LinkedBankAccount.swift
//  CashbackCounter
//
//  一个已绑定的银行账户（一张信用卡）在本地的映射。
//
//  为什么这份记录要存在本地而不是每次问后端：
//  后端只知道 item 和 account 的存在，它**不知道**这个账户对应你卡包里的哪张卡、
//  你有没有关掉它的同步、上次同步到哪一天了。这些是纯客户端的状态，
//  而且同步引擎每次跑都要读它们 —— 放本地才谈得上离线可用和即时响应。
//

import Foundation
import SwiftData

@Model
final class LinkedBankAccount {

    // MARK: - Plaid 标识

    /// 一次银行绑定。同一家银行的多张卡共享同一个 itemId，解绑是按 item 解的
    var itemId: String = ""

    /// 具体某个账户（某张卡）。同步、去重都以它为最小粒度
    var accountId: String = ""

    // MARK: - 展示用

    var institutionName: String = ""
    var accountName: String = ""

    /// 账户尾号，例如 "1111"。
    /// **这是 Plaid 能给的最详细的卡标识——完整卡号任何产品都拿不到**（PCI DSS 管辖范围）。
    /// 自动匹配卡片靠的就是它和 CreditCard.endNum 对比。
    var mask: String = ""

    // MARK: - 关联与状态

    /// 匹配到的本地卡片。
    ///
    /// 可空且**删卡不删这条绑定记录** —— 用户重建卡片后可以重新关联，
    /// 而绑定关系是和银行之间的，不该因为本地整理卡包而丢失。
    ///
    /// ⚠️ 这里**不写 @Relationship**：inverse 声明在 CreditCard.linkedBankAccounts 那一侧，
    /// 和本项目其它关系的写法一致。两边都写会重复定义。
    /// 而两边**都不写** inverse 会让整个 schema 不兼容 CloudKit（见 CreditCard 那边的注释），
    /// 后果是灾难性的 —— 别把它删掉。
    var card: CreditCard?

    /// 用户可以单独关掉某张卡的同步。
    ///
    /// 默认 false：没匹配到卡就没有费率规则，算不出返现和积分，
    /// 同步进来只是一堆算不了奖励的流水。匹配成功时才由调用方置 true。
    var syncEnabled: Bool = false

    /// 增量同步的水位线。nil 表示还没成功同步过
    var lastSyncedAt: Date?

    /// 首次全量拉取是否已完成。
    /// 没完成之前每次同步都走全量分段拉取，完成后才转增量。
    var didInitialSync: Bool = false

    var linkedAt: Date = Date()

    init(itemId: String,
         accountId: String,
         institutionName: String,
         accountName: String,
         mask: String,
         card: CreditCard? = nil,
         syncEnabled: Bool = false) {
        self.itemId = itemId
        self.accountId = accountId
        self.institutionName = institutionName
        self.accountName = accountName
        self.mask = mask
        self.card = card
        self.syncEnabled = syncEnabled
        self.linkedAt = Date()
    }
}

extension LinkedBankAccount {

    /// 列表里那行副标题："Chase Sapphire ···1234"
    var displayTitle: String {
        mask.isEmpty ? accountName : "\(accountName) ···\(mask)"
    }

    /// 真正会被同步的条件：开了开关**并且**关联了卡片。
    ///
    /// 两个条件都查，而不是只信 syncEnabled —— 卡片可能在开启同步之后才被删除，
    /// 那时 card 变成 nil 但 syncEnabled 还是 true。少查一个条件，
    /// 同步引擎就会拿着 nil 卡片去算费率。
    var isSyncable: Bool {
        syncEnabled && card != nil
    }
}
