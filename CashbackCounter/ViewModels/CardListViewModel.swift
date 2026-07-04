//
//  CardListViewModel.swift
//  CashbackCounter
//

import SwiftUI
import SwiftData

@Observable
final class CardListViewModel {
    // MARK: - Sheet/Edit State
    var cardToEdit: CreditCard?
    var activeSheet: SheetType?
    
    // MARK: - Import/Export State
    var showFileExporter = false
    var showFileImporter = false
    var importError: String?
    var showImportAlert = false
    /// 点击导出按钮后生成的文件 URL（延迟生成，避免在视图构建时打包阻塞主线程）
    var exportedFileURL: URL? = nil
    
    // MARK: - Card Selection State
    var selectedCardID: PersistentIdentifier? = nil
    var scrollOffset: CGFloat = 0
    
    // MARK: - Computed
    
    var isDetailMode: Bool {
        selectedCardID != nil
    }
    
    func selectedCardTransactions(from cards: [CreditCard]) -> [Transaction] {
        guard let selectedCard = cards.first(where: { $0.id == selectedCardID }) else {
            return []
        }
        return (selectedCard.transactions ?? []).sorted { $0.date > $1.date }
    }
    
    // MARK: - Actions
    
    func toggleCardSelection(_ card: CreditCard) {
        if card.id == selectedCardID {
            selectedCardID = nil
        } else {
            selectedCardID = card.id
        }
    }
    
    func deleteSelectedCard(from cards: [CreditCard], context: ModelContext) {
        guard let selectedID = selectedCardID,
              let selectedCard = cards.first(where: { $0.id == selectedID }) else { return }
        selectedCardID = nil
        NotificationManager.shared.cancelNotification(for: selectedCard)
        context.delete(selectedCard)
    }
    
    func handleCardImport(result: Result<[URL], Error>, context: ModelContext) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                try CardCSVHelper.parseCSV(content: content, into: context)
                importError = nil
            } catch {
                importError = "导入失败：格式错误或文件损坏。\n\(error.localizedDescription)"
                showImportAlert = true
            }
        case .failure(let error):
            print("选择文件失败: \(error.localizedDescription)")
        }
    }
}
