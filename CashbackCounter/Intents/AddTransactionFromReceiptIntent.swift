//
//  AddTransactionFromReceiptIntent.swift
//  CashbackCounter
//
//  Created by Junhao Huang on 12/1/25.
//

import AppIntents
import SwiftData
import Vision
import VisualIntelligence // 为了用 SemanticContentDescriptor


struct AddTransactionFromReceiptIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Transaction from Receipt"

    // 如果你不走 Visual Intelligence，也可以用 @Parameter 接 UIImage/INFile，这里先用 SemanticContentDescriptor 展示
    @Parameter(title: "Receipt")
    var semanticContent: SemanticContentDescriptor

    @Dependency var modelContext: ModelContext
    
    
    
    private static let sharedModelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: Transaction.self, CreditCard.self)
        } catch {
            fatalError("Failed to create shared model container: \(error)")
        }
    }()
    
    @MainActor
    func perform() async throws -> some IntentResult {
        
        let modelContext = ModelContext(Self.sharedModelContainer)
        let parser = ReceiptParser()

        guard let pixelBuffer = semanticContent.pixelBuffer else {
            // 没有图片，直接结束
            return .result()
        }

        // 1. OCR + 解析
        let metadata = await OCRService.analyzeImage(pixelBuffer)
        // 2. 写入 SwiftData（根据你自己的模型结构来）
        let transaction = Transaction(
            id: UUID(),
            amount: info.amount,
            date: info.date,
            merchant: info.merchant
            // ...
        )

        modelContext.insert(transaction)
        try modelContext.save()

        // 3. 如果你有 TransactionEntity，可以返回给捷径/Spotlight 用
        // let entity = TransactionEntity(transaction: transaction)
        // return .result(value: entity)

        return .result()
    }
}
