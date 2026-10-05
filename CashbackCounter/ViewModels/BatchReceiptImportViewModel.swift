//
//  BatchReceiptImportViewModel.swift
//  CashbackCounter
//
//  批量导入收据：多选图片 → 逐张 AI 识别 → 审核后批量建账单
//

import SwiftUI
import SwiftData
import PhotosUI
import ImageIO

@Observable
final class BatchReceiptImportViewModel {

    // MARK: - Nested Types

    enum DraftStatus {
        case pending      // 排队等待识别
        case analyzing    // 正在识别
        case recognized   // 识别出金额，可直接保存
        case failed       // 没识别出金额，需要用户点开补充
    }

    struct Draft: Identifiable {
        let id = UUID()
        /// 只存压缩后的原始数据，用到时再解码：20 张相机原图同时解码成位图会吃掉上 GB 内存
        let imageData: Data
        let thumbnail: UIImage
        var status: DraftStatus = .pending
        var merchant: String = ""
        var amount: Double?
        var date: Date = Date()
        var category: Category = .other
        /// nil = 没识别出币种，保存时按所用卡的发卡地区
        var location: Region?
        var cardLast4: String?
    }

    /// 单次最多导入张数：识别是串行的，太多张用户要等很久
    static let maxCount = 20
    /// 识别和入库用的图片尺寸上限，与 OCRService 内部的 2500px 缩放保持一致
    private static let workingMaxDimension: CGFloat = 2500
    private static let thumbnailMaxDimension: CGFloat = 240

    // MARK: - State

    var drafts: [Draft] = []
    var isLoadingImages = false
    var isSaving = false
    var unreadableCount = 0

    var editingDraft: Draft?
    private(set) var editingImage: UIImage?

    private var analysisTask: Task<Void, Never>?

    init(drafts: [Draft] = []) {
        self.drafts = drafts
    }

    // MARK: - Computed

    var isAnalyzing: Bool {
        drafts.contains { $0.status == .pending || $0.status == .analyzing }
    }

    var finishedCount: Int { drafts.filter { $0.status == .recognized || $0.status == .failed }.count }
    var remainingSlots: Int { max(Self.maxCount - drafts.count, 0) }

    /// 只按小票上识别出的卡号尾号匹配，不回落到任何默认卡：
    /// 一批收据可能来自不同的卡，猜错卡会让返现记到别的卡上
    func card(for draft: Draft, cards: [CreditCard]) -> CreditCard? {
        guard let last4 = draft.cardLast4, !last4.isEmpty else { return nil }
        return cards.first { $0.endNum == last4 }
    }

    /// 金额识别出来且匹配到了卡，才能不经确认直接批量保存
    func isReady(_ draft: Draft, cards: [CreditCard]) -> Bool {
        draft.status == .recognized && card(for: draft, cards: cards) != nil
    }

    func readyCount(cards: [CreditCard]) -> Int {
        drafts.filter { isReady($0, cards: cards) }.count
    }

    func region(for draft: Draft, cards: [CreditCard]) -> Region {
        draft.location ?? card(for: draft, cards: cards)?.issueRegion ?? .cn
    }

    // MARK: - Loading

    @MainActor
    func addImages(from items: [PhotosPickerItem]) async {
        isLoadingImages = true
        defer { isLoadingImages = false }

        var unreadable = 0
        for item in items.prefix(remainingSlots) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let thumbnail = await Self.decode(data, maxDimension: Self.thumbnailMaxDimension) else {
                unreadable += 1
                continue
            }
            drafts.append(Draft(imageData: data, thumbnail: thumbnail))
        }
        unreadableCount = unreadable
        startAnalysisIfNeeded()
    }

    // MARK: - Analysis

    /// 串行识别：端侧模型同时跑多路只会互相抢资源，而且结果顺序会乱
    private func startAnalysisIfNeeded() {
        guard analysisTask == nil else { return }
        analysisTask = Task {
            while !Task.isCancelled, let index = drafts.firstIndex(where: { $0.status == .pending }) {
                let id = drafts[index].id
                drafts[index].status = .analyzing

                var metadata: ReceiptMetadata?
                if let image = await Self.decode(drafts[index].imageData, maxDimension: Self.workingMaxDimension) {
                    metadata = await OCRService.analyzeImage(image)
                }
                guard !Task.isCancelled else { break }
                // 识别期间用户可能删掉了这张，按 id 重新定位
                guard let current = drafts.firstIndex(where: { $0.id == id }) else { continue }
                apply(metadata, to: &drafts[current])
            }
            // 被取消时 cancelAnalysis 已清空引用，之后可能已经起了新任务，不能再覆盖
            if !Task.isCancelled { analysisTask = nil }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        // 被打断的那张退回排队，之后再加图或点重新识别时会一并重新识别
        for index in drafts.indices where drafts[index].status == .analyzing {
            drafts[index].status = .pending
        }
    }

    func retry(_ draft: Draft) {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        drafts[index].status = .pending
        startAnalysisIfNeeded()
    }

    func remove(id: Draft.ID) {
        drafts.removeAll { $0.id == id }
    }

    private func apply(_ metadata: ReceiptMetadata?, to draft: inout Draft) {
        guard let metadata else {
            draft.status = .failed
            return
        }
        draft.merchant = metadata.merchant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        draft.amount = metadata.totalAmount.map { abs($0) }
        // 模型偶尔把年份认错成未来日期，账单日期不能晚于今天
        if let dateString = metadata.dateString { draft.date = min(dateString.toDate(), Date()) }
        draft.category = metadata.category ?? .other
        draft.location = metadata.currency.flatMap(Region.from(currencyText:))
        draft.cardLast4 = metadata.cardLast4?.filter(\.isNumber)
        draft.status = draft.amount == nil ? .failed : .recognized
    }

    // MARK: - Editing

    /// 点开单张进完整记账表单；图片在这里解码一次，避免 sheet 内容每次重建都重新解码
    func beginEditing(_ draft: Draft) {
        editingImage = Self.decodeSync(draft.imageData, maxDimension: Self.workingMaxDimension)
        editingDraft = draft
    }

    func endEditing() {
        editingImage = nil
    }

    // MARK: - Save

    /// 保存所有识别出金额且匹配到卡的收据，返回成功条数。其余的留在列表里等用户点开补充。
    @MainActor
    func saveRecognized(cards: [CreditCard], context: ModelContext) async -> Int {
        isSaving = true
        defer { isSaving = false }

        var savedIDs: [Draft.ID] = []
        for draft in drafts where isReady(draft, cards: cards) {
            guard let amount = draft.amount,
                  let card = card(for: draft, cards: cards),
                  let cardIndex = cards.firstIndex(of: card),
                  let image = await Self.decode(draft.imageData, maxDimension: Self.workingMaxDimension) else { continue }

            let location = region(for: draft, cards: cards)
            let billingAmount = await convertedBillingAmount(amount, from: location, to: card.billingRegion(for: location))

            // 复用单张记账的保存逻辑：返现/积分上限计算、收据压缩、挂到卡上，都与手动记一笔完全一致。
            // 每次保存都会立即写入 card.transactions，下一张的上限计算能看到前面刚存的这几笔。
            let form = AddTransactionViewModel(
                image: image,
                prefillMerchant: draft.merchant.isEmpty ? String.loc("未知商户") : draft.merchant,
                prefillAmount: amount,
                prefillBillingAmount: billingAmount,
                prefillDate: draft.date,
                prefillCategory: draft.category,
                prefillLocation: location
            )
            form.selectedCardIndex = cardIndex
            await form.saveTransaction(cards: cards, context: context)
            savedIDs.append(draft.id)
        }

        drafts.removeAll { savedIDs.contains($0.id) }
        return savedIDs.count
    }

    /// 消费币种与入账币种不同时按当日汇率换算；取不到汇率返回 nil，入账金额按原币金额记
    private func convertedBillingAmount(_ amount: Double, from location: Region, to billingRegion: Region) async -> Double? {
        guard location.currencyCode != billingRegion.currencyCode else { return nil }
        let rates = await CurrencyService.getRates(base: location.currencyCode)
        guard let rate = rates[billingRegion.currencyCode.lowercased()], rate > 0 else { return nil }
        return amount * rate
    }

    // MARK: - Image Decoding

    /// 用 ImageIO 直接按目标尺寸解码，不经过全尺寸位图；同时应用 EXIF 方向
    nonisolated private static func decodeSync(_ data: Data, maxDimension: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func decode(_ data: Data, maxDimension: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            decodeSync(data, maxDimension: maxDimension)
        }.value
    }
}
