//
//  CreditCardRepository.swift
//  CashbackCounter
//

import Foundation
import SwiftData

// MARK: - Protocol

protocol CreditCardRepository {
    func fetchAll() -> [CreditCard]
    func fetchSorted() -> [CreditCard]
    func insert(_ card: CreditCard)
    func delete(_ card: CreditCard)
    func save() throws
}

// MARK: - SwiftData Implementation

@Observable
final class SwiftDataCreditCardRepository: CreditCardRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetchAll() -> [CreditCard] {
        let descriptor = FetchDescriptor<CreditCard>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// 按卡包里的自定义顺序取卡，同序号再按银行名。
    /// 之前的签名收一个 keyPath 字符串却固定按 bankName 排，调用方会被参数误导
    func fetchSorted() -> [CreditCard] {
        let descriptor = FetchDescriptor<CreditCard>(
            sortBy: [SortDescriptor(\CreditCard.sortIndex), SortDescriptor(\CreditCard.bankName)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func insert(_ card: CreditCard) {
        modelContext.insert(card)
    }

    func delete(_ card: CreditCard) {
        modelContext.delete(card)
    }

    func save() throws {
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }
}
