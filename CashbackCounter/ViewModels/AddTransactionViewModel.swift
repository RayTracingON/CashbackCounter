//
//  AddTransactionViewModel.swift
//  CashbackCounter
//

import SwiftUI
import SwiftData

@Observable
final class AddTransactionViewModel {
    // MARK: - Form State
    var merchant: String = ""
    var amount: String = ""
    var selectedCategory: Category = .dining
    var date: Date = Date()
    var selectedCardIndex: Int = 0
    var location: Region = .cn
    var billingAmountStr: String = ""
    var receiptImage: UIImage?
    var paymentMethod: PaymentMethod = .offline
    var rewardPreview: RewardPreview?
    // 双币卡：手动覆盖入账币种 (nil = 按卡片规则自动判定)
    var billingRegionOverride: Region? = nil

    // AI 分析状态
    var isAnalyzing: Bool = false
    var showFullImage = false
    var showImagePicker: Bool = false

    // Edit/Prefill context
    var transactionToEdit: Transaction?
    let prefillCardLast4: String?
    let shouldSkipRateUpdate: Bool

    /// 新建交易预先定好的 dedupeID。预览和保存后的周期重算都按 (日期, dedupeID) 排序，
    /// 提前定下来，预览里看到的额度分配才和保存后一致
    let pendingDedupeID = UUID().uuidString

    /// 积分卡预览要先查一次估值（可能走网络），快速连续输入时只保留最后一次
    private var previewTask: Task<Void, Never>?

    // 编辑模式下记录原始收据：只有用户换图/删图时才重新压缩写入，
    // 避免每次编辑都 解码→再压缩 导致画质逐次劣化
    private var originalReceiptData: Data?
    private var originalReceiptImage: UIImage?

    // 进行中的小票识别：删图/换图时取消，避免旧图结果晚到覆盖表单
    private var analysisTask: Task<Void, Never>?

    // MARK: - Nested Types

    struct RewardPreview {
        let value: Double
        let points: Int
        let isCapped: Bool
    }

    // MARK: - Init

    init(
        transaction: Transaction? = nil,
        image: UIImage? = nil,
        prefillMerchant: String? = nil,
        prefillAmount: Double? = nil,
        prefillBillingAmount: Double? = nil,
        prefillDate: Date? = nil,
        prefillCategory: Category? = nil,
        prefillLocation: Region? = nil,
        prefillPaymentMethod: PaymentMethod? = nil,
        prefillCardLast4: String? = nil
    ) {
        self.transactionToEdit = transaction
        self.prefillCardLast4 = prefillCardLast4
        self.shouldSkipRateUpdate = transaction != nil || prefillBillingAmount != nil

        if let t = transaction {
            merchant = t.merchant
            amount = String(t.amount)
            billingAmountStr = String(t.billingAmount)
            selectedCategory = t.category
            date = t.date
            location = t.location
            paymentMethod = t.paymentMethod

            if let data = t.receiptData {
                originalReceiptData = data
                receiptImage = UIImage(data: data)
                originalReceiptImage = receiptImage
            }

            // 已存入账币种与卡片自动判定不一致时，还原为手动覆盖
            if let code = t.billingCurrencyCode,
               let region = Region.from(currencyCode: code),
               let card = t.card,
               region != card.billingRegion(for: t.location) {
                billingRegionOverride = region
            }
        } else {
            receiptImage = image

            if let prefillMerchant {
                merchant = prefillMerchant
            }

            let displayAmount = prefillAmount ?? prefillBillingAmount
            if let displayAmount {
                amount = String(format: "%.2f", displayAmount)
            }

            if let prefillBillingAmount {
                billingAmountStr = String(format: "%.2f", prefillBillingAmount)
            } else if let displayAmount {
                billingAmountStr = String(format: "%.2f", displayAmount)
            }

            if let prefillDate { date = prefillDate }
            if let prefillCategory { selectedCategory = prefillCategory }
            if let prefillLocation { location = prefillLocation }
            if let prefillPaymentMethod { paymentMethod = prefillPaymentMethod }
        }
    }

    // MARK: - Computed

    /// 本笔交易的入账币种地区：手动覆盖优先，否则按卡片规则自动判定
    func resolvedBillingRegion(cards: [CreditCard]) -> Region {
        if let override = billingRegionOverride { return override }
        guard cards.indices.contains(selectedCardIndex) else { return location }
        return cards[selectedCardIndex].billingRegion(for: location)
    }

    func currentCurrencySymbol(cards: [CreditCard]) -> String {
        if cards.indices.contains(selectedCardIndex) {
            return resolvedBillingRegion(cards: cards).currencySymbol
        }
        return "¥"
    }

    // MARK: - Card Selection

    func applyPrefillCardSelection(cards: [CreditCard]) {
        guard transactionToEdit == nil else { return }
        if let prefillCardLast4, let index = cards.firstIndex(where: { $0.endNum == prefillCardLast4 }) {
            selectedCardIndex = index
            return
        }
        if let card = CreditCard.defaultCard(in: cards), let index = cards.firstIndex(of: card) {
            selectedCardIndex = index
        }
    }

    // MARK: - AI Analysis

    /// - Parameter force: 用户主动选了新图时传 true。表单可能已被上一张图的识别结果填过，
    ///   不能再以"商户/金额非空"为由跳过，否则删图后重新上传不会触发识别
    func analyzeReceipt(cards: [CreditCard], force: Bool = false) {
        guard let image = receiptImage else { return }
        if !force && (!merchant.isEmpty || !amount.isEmpty) { return }
        analysisTask?.cancel()
        isAnalyzing = true

        analysisTask = Task {
            let metadata = await OCRService.analyzeImage(image)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isAnalyzing = false
                if let data = metadata {
                    if let amt = data.totalAmount { self.amount = String(format: "%.2f", abs(amt)) }
                    if let merch = data.merchant { self.merchant = merch }
                    if let dateStr = data.dateString { self.date = dateStr.toDate() }
                    if let last4 = data.cardLast4, let index = cards.firstIndex(where: { $0.endNum == last4 }) {
                        self.selectedCardIndex = index
                    } else if let card = CreditCard.defaultCard(in: cards), let index = cards.firstIndex(of: card) {
                        self.selectedCardIndex = index
                    }
                    if let cat = data.category { self.selectedCategory = cat }
                    if let currency = data.currency, let region = Region.from(currencyText: currency) {
                        self.location = region
                    }
                }
            }
        }
    }

    func cancelReceiptAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
    }

    // MARK: - Reward Preview

    @MainActor
    func updateRewardPreview(cards: [CreditCard]) {
        guard let amountDouble = Double(amount),
              cards.indices.contains(selectedCardIndex) else {
            rewardPreview = nil
            return
        }

        let card = cards[selectedCardIndex]
        let finalAmount = Double(billingAmountStr) ?? amountDouble

        // 和保存后的周期重算用同一套顺序与封顶算法：放进所属周期按时间模拟
        let result = card.simulateReward(
            amount: finalAmount,
            category: selectedCategory,
            location: location,
            date: date,
            paymentMethod: paymentMethod,
            transactionToExclude: transactionToEdit,
            sortKey: transactionToEdit?.dedupeID ?? pendingDedupeID
        )

        if card.rewardType == .points {
            rewardPreview = nil
            previewTask?.cancel()
            previewTask = Task {
                let pointValue = await card.pointValueInCardCurrency()
                guard !Task.isCancelled else { return }
                // 之前用「理论价值 ÷ 每分价值」估理论积分数，但理论值本身已经是积分数，
                // 再除一次就放大了 1/pointValue 倍 —— 积分卡预览永远显示"已达上限"
                let reward = CreditCard.pointsReward(fromCappedTotal: result.capped, pointValueInCardCurrency: pointValue)
                await MainActor.run {
                    rewardPreview = RewardPreview(value: reward.value, points: reward.points, isCapped: result.isCapped)
                }
            }
        } else {
            rewardPreview = RewardPreview(value: result.capped, points: 0, isCapped: result.isCapped)
        }
    }

    // MARK: - Billing Amount

    func updateBillingAmount(cards: [CreditCard]) {
        guard let amountDouble = Double(amount) else { return }
        guard cards.indices.contains(selectedCardIndex) else {
            billingAmountStr = amount
            return
        }
        let sourceCurrency = location.currencyCode
        let targetCurrency = resolvedBillingRegion(cards: cards).currencyCode

        if sourceCurrency == targetCurrency {
            billingAmountStr = String(format: "%.2f", amountDouble)
            return
        }

        guard transactionToEdit == nil else { return }
        if shouldSkipRateUpdate { return }

        Task {
            let rates = await CurrencyService.getRates(base: sourceCurrency)
            if let rate = rates[targetCurrency.lowercased()], rate > 0 {
                let billing = amountDouble * rate
                await MainActor.run {
                    self.billingAmountStr = String(format: "%.2f", billing)
                }
            } else {
                print("汇率获取失败: 缺少 \(sourceCurrency)->\(targetCurrency) 汇率")
            }
        }
    }

    // MARK: - Save

    @MainActor
    func saveTransaction(cards: [CreditCard], context: ModelContext) async {
        guard let amountDouble = Double(amount) else { return }
        let billingDouble = Double(billingAmountStr) ?? amountDouble

        if cards.indices.contains(selectedCardIndex) {
            let card = cards[selectedCardIndex]

            // 收据数据：未改动时沿用原始 Data，避免反复 JPEG 压缩劣化画质
            let imageData: Data?
            if let image = receiptImage {
                if image === originalReceiptImage, let original = originalReceiptData {
                    imageData = original
                } else {
                    imageData = image.jpegData(compressionQuality: AppConfig.receiptJPEGQuality)
                }
            } else {
                imageData = nil
            }

            let (finalCashback, pointsEarned) = await card.cappedReward(
                amount: billingDouble,
                category: selectedCategory,
                location: location,
                date: date,
                paymentMethod: paymentMethod,
                transactionToExclude: transactionToEdit
            )

            let nominalRate = card.getRate(for: selectedCategory, location: location, payment: paymentMethod)
            let billingCode = resolvedBillingRegion(cards: cards).currencyCode

            if let t = transactionToEdit {
                // --- 编辑模式 ---
                // 换卡或跨周期移动时，原来那边的周期也要重算
                let previousCard = t.card
                let previousDate = t.date
                // ⚠️ 必须先比较再赋值：判断条件里用到的旧值（如 t.date）一旦先被覆盖，比较就永远为 false
                let needsRewardUpdate = t.card != card ||
                    t.billingAmount != billingDouble ||
                    t.category != selectedCategory ||
                    t.paymentMethod != paymentMethod ||
                    t.date != date ||
                    t.cashbackamount != finalCashback ||
                    t.pointsEarned != pointsEarned ||
                    t.billingCurrencyCode != billingCode

                t.merchant = merchant
                t.amount = amountDouble
                t.location = location
                t.date = date

                if needsRewardUpdate {
                    t.card = card
                    t.billingAmount = billingDouble
                    t.category = selectedCategory
                    t.paymentMethod = paymentMethod
                    t.billingCurrencyCode = billingCode

                    t.rate = nominalRate
                    t.cashbackamount = finalCashback
                    t.pointsEarned = pointsEarned
                }

                if t.receiptData != imageData {
                    t.receiptData = imageData
                }

                // 周期内顺序重算：这一笔和同周期其它交易的额度分配都可能变。
                // 先 save 让关系数组（card.transactions）稳定下来再算
                try? context.save()
                await card.recalculateRewards(inPeriodOf: date)
                if let previousCard, previousCard != card {
                    await previousCard.recalculateRewards(inPeriodOf: previousDate)
                } else if card.periodKey(for: previousDate) != card.periodKey(for: date) {
                    await card.recalculateRewards(inPeriodOf: previousDate)
                }

            } else {
                // --- 新建模式 ---
                let newTransaction = Transaction(
                    merchant: merchant,
                    category: selectedCategory,
                    location: location,
                    amount: amountDouble,
                    date: date,
                    card: card,
                    receiptData: imageData,
                    billingAmount: billingDouble,
                    cashbackAmount: finalCashback,
                    pointsEarned: pointsEarned,
                    paymentMethod: paymentMethod,
                    billingCurrencyCode: billingCode
                )
                // 和预览时用的顺序键一致
                newTransaction.dedupeID = pendingDedupeID
                context.insert(newTransaction)

                if card.transactions == nil {
                    card.transactions = [newTransaction]
                } else {
                    card.transactions?.append(newTransaction)
                }

                // 补录早于同周期其它交易的日期时，额度要重新按时间顺序分配
                try? context.save()
                await card.recalculateRewards(inPeriodOf: date)
            }

            try? context.save()
        }
    }
}
