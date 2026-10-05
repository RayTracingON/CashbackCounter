//
//  BatchReceiptImportView.swift
//  CashbackCounter
//

import SwiftUI
import SwiftData
import PhotosUI

struct BatchReceiptImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var cards: [CreditCard]

    /// 从「拍一笔」相册多选进来时已经选好的图片，进入页面后直接开始识别
    private let initialItems: [PhotosPickerItem]

    @State private var viewModel: BatchReceiptImportViewModel
    @State private var showPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var didLoadInitialItems = false
    @State private var showDiscardConfirm = false
    @State private var resultMessage: String?

    init(initialItems: [PhotosPickerItem] = [],
         viewModel: BatchReceiptImportViewModel = BatchReceiptImportViewModel()) {
        self.initialItems = initialItems
        _viewModel = State(initialValue: viewModel)
    }

    private var readyCount: Int { viewModel.readyCount(cards: cards) }

    var body: some View {
        NavigationStack {
            Group {
                // 带图进来时，读图开始前的那一帧不能闪出空状态
                if viewModel.drafts.isEmpty && !viewModel.isLoadingImages
                    && (initialItems.isEmpty || didLoadInitialItems) {
                    emptyState
                } else {
                    draftList
                }
            }
            .overlay {
                if viewModel.isSaving {
                    ProgressView("保存中...")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(DesignConstants.CornerRadius.large)
                }
            }
            .navigationTitle("批量导入收据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if viewModel.drafts.isEmpty { dismiss() } else { showDiscardConfirm = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存 \(readyCount) 笔") { saveRecognized() }
                        .disabled(readyCount == 0 || viewModel.isAnalyzing || viewModel.isLoadingImages
                                  || viewModel.isSaving)
                }
            }
        }
        // 有未保存的收据时禁止下滑关闭，避免一划就丢掉识别结果
        .interactiveDismissDisabled(!viewModel.drafts.isEmpty)
        .confirmationDialog("放弃未保存的收据？", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("放弃", role: .destructive) { dismiss() }
        }
        .alert("导入结果", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("确定", role: .cancel) { }
        } message: { Text(resultMessage ?? "") }
        .photosPicker(
            isPresented: $showPicker,
            selection: $pickerItems,
            maxSelectionCount: max(viewModel.remainingSlots, 1),
            selectionBehavior: .ordered,
            matching: .images
        )
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await addImages(items) }
        }
        .task {
            guard !initialItems.isEmpty, !didLoadInitialItems else { return }
            didLoadInitialItems = true
            await addImages(initialItems)
        }
        .sheet(item: $viewModel.editingDraft, onDismiss: viewModel.endEditing) { draft in
            AddTransactionView(
                image: viewModel.editingImage,
                prefillMerchant: draft.merchant.isEmpty ? nil : draft.merchant,
                prefillAmount: draft.amount,
                prefillDate: draft.date,
                prefillCategory: draft.category,
                prefillLocation: viewModel.region(for: draft, cards: cards),
                prefillCardLast4: viewModel.card(for: draft, cards: cards)?.endNum,
                onSaved: { viewModel.remove(id: draft.id) }
            )
        }
        .onAppear {
            OCRService.prewarmAI()
        }
        .onDisappear {
            viewModel.cancelAnalysis()
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("批量导入收据", systemImage: "photo.stack")
        } description: {
            Text("一次最多选 \(BatchReceiptImportViewModel.maxCount) 张，AI 会逐张识别生成账单，保存前可以逐条检查修改")
        } actions: {
            Button("选择收据图片") { showPicker = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var draftList: some View {
        List {
            if cards.isEmpty {
                Section {
                    Text("请先添加信用卡").foregroundColor(.secondary)
                }
            }

            Section {
                if viewModel.isLoadingImages {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在读取图片...").foregroundColor(.secondary)
                    }
                } else if viewModel.isAnalyzing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(String.loc("正在识别 \(viewModel.finishedCount)/\(viewModel.drafts.count)"))
                            .foregroundColor(.secondary)
                    }
                }

                ForEach(viewModel.drafts) { draft in
                    let card = viewModel.card(for: draft, cards: cards)
                    DraftRow(draft: draft, card: card, region: viewModel.region(for: draft, cards: cards))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard draft.status == .recognized || draft.status == .failed else { return }
                            viewModel.beginEditing(draft)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                viewModel.remove(id: draft.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            if draft.status == .failed {
                                Button {
                                    viewModel.retry(draft)
                                } label: {
                                    Label("重新识别", systemImage: "arrow.clockwise")
                                }
                                .tint(.blue)
                            }
                        }
                }

                if viewModel.remainingSlots > 0 {
                    Button {
                        showPicker = true
                    } label: {
                        Label(String.loc("继续添加（还可选 \(viewModel.remainingSlots) 张）"), systemImage: "plus")
                    }
                    .disabled(viewModel.isLoadingImages)
                }
            } footer: {
                Text("每张收据按小票上的卡号尾号匹配卡片。点按可逐条修改，左滑可删除；没识别出金额或没匹配到卡片的不会被批量保存，需要点开手动补充。")
            }
        }
    }

    // MARK: - Actions

    private func addImages(_ items: [PhotosPickerItem]) async {
        await viewModel.addImages(from: items)
        if viewModel.unreadableCount > 0 {
            resultMessage = String.loc("有 \(viewModel.unreadableCount) 张图片无法读取，已跳过")
        }
    }

    private func saveRecognized() {
        Task {
            let saved = await viewModel.saveRecognized(cards: cards, context: context)
            if viewModel.drafts.isEmpty {
                dismiss()
            } else {
                resultMessage = String.loc("已保存 \(saved) 笔，还有 \(viewModel.drafts.count) 张需要手动补充")
            }
        }
    }
}

// MARK: - Draft Row

private struct DraftRow: View {
    let draft: BatchReceiptImportViewModel.Draft
    let card: CreditCard?
    let region: Region

    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: draft.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .foregroundColor(draft.merchant.isEmpty ? .secondary : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(draft.status == .failed || needsCard ? .orange : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            trailing
        }
        .padding(.vertical, 2)
    }

    /// 金额识别出来了，但小票上的卡号尾号没对上卡包里的任何一张卡
    private var needsCard: Bool { draft.status == .recognized && card == nil }

    private var title: String {
        switch draft.status {
        case .pending: return String.loc("等待识别")
        case .analyzing: return String.loc("AI 分析中...")
        case .recognized: return draft.merchant.isEmpty ? String.loc("未知商户") : draft.merchant
        case .failed: return draft.merchant.isEmpty ? String.loc("识别失败") : draft.merchant
        }
    }

    private var subtitle: String {
        switch draft.status {
        case .pending, .analyzing:
            return ""
        case .failed:
            return String.loc("未识别出金额，点按手动补充")
        case .recognized:
            guard let card else { return String.loc("未匹配到卡片，点按选择") }
            return [
                draft.date.formatted(.dateTime.month().day().locale(AppLanguage.locale)),
                draft.category.displayName,
                card.bankName + " " + card.type
            ].joined(separator: " · ")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch draft.status {
        case .pending:
            Image(systemName: "clock").foregroundColor(.secondary)
        case .analyzing:
            ProgressView()
        case .recognized:
            if let amount = draft.amount {
                Text("\(region.currencySymbol)\(String(format: "%.2f", amount))")
                    .fontWeight(.semibold)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        }
    }
}

// MARK: - Previews

#if DEBUG
extension BatchReceiptImportViewModel {
    static var preview: BatchReceiptImportViewModel {
        let data = PreviewData.receiptImage.jpegData(compressionQuality: 0.8) ?? Data()
        func draft(_ status: DraftStatus, merchant: String = "", amount: Double? = nil,
                   category: Category = .other, location: Region? = nil, cardLast4: String? = nil) -> Draft {
            var draft = Draft(imageData: data, thumbnail: PreviewData.receiptImage)
            draft.status = status
            draft.merchant = merchant
            draft.amount = amount
            draft.category = category
            draft.location = location
            draft.cardLast4 = cardLast4
            return draft
        }
        return BatchReceiptImportViewModel(drafts: [
            draft(.recognized, merchant: "山姆会员店", amount: 486.5, category: .grocery, location: .cn, cardLast4: "6688"),
            // 小票上的尾号对不上卡包里的卡：提示点开选卡，不进批量保存
            draft(.recognized, merchant: "Lawson", amount: 1_280, category: .dining, location: .jp, cardLast4: "0000"),
            draft(.failed),
            draft(.analyzing),
            draft(.pending)
        ])
    }
}

#Preview("批量导入 · 未选图") {
    BatchReceiptImportView()
        .previewEnvironment()
}

#Preview("批量导入 · 识别中") {
    // 已识别 / 未匹配到卡 / 识别失败 / 识别中 / 排队 各一行
    BatchReceiptImportView(viewModel: .preview)
        .previewEnvironment()
}

#Preview("批量导入 · 卡包为空") {
    BatchReceiptImportView(viewModel: .preview)
        .previewEmptyEnvironment()
}
#endif
