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

    // 编辑模式下记录原始收据：只有用户换图/删图时才重新压缩写入，
    // 避免每次编辑都 解码→再压缩 导致画质逐次劣化
    private var originalReceiptData: Data?
    private var originalReceiptImage: UIImage?

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
        
        let defaultCardID = UserDefaults.standard.string(forKey: "defaultCardID") ?? ""
        if !defaultCardID.isEmpty {
            let parts = defaultCardID.split(separator: "|")
            if parts.count == 2 {
                let bank = String(parts[0])
                let end = String(parts[1])
                if let index = cards.firstIndex(where: { $0.bankName == bank && $0.endNum == end }) {
                    selectedCardIndex = index
                }
            }
        }
    }

    // MARK: - AI Analysis

    func analyzeReceipt(cards: [CreditCard]) {
        guard let image = receiptImage else { return }
        if !merchant.isEmpty || !amount.isEmpty { return }
        isAnalyzing = true

        Task {
            let metadata = await OCRService.analyzeImage(image)
            await MainActor.run {
                isAnalyzing = false
                if let data = metadata {
                    if let amt = data.totalAmount { self.amount = String(format: "%.2f", abs(amt)) }
                    if let merch = data.merchant { self.merchant = merch }
                    if let dateStr = data.dateString { self.date = dateStr.toDate() }
                    if let last4 = data.cardLast4, let index = cards.firstIndex(where: { $0.endNum == last4 }) {
                        self.selectedCardIndex = index
                    } else {
                        let defaultCardID = UserDefaults.standard.string(forKey: "defaultCardID") ?? ""
                        if !defaultCardID.isEmpty {
                            let parts = defaultCardID.split(separator: "|")
                            if parts.count == 2 {
                                let bank = String(parts[0])
                                let end = String(parts[1])
                                if let index = cards.firstIndex(where: { $0.bankName == bank && $0.endNum == end }) {
                                    self.selectedCardIndex = index
                                }
                            }
                        }
                    }
                    if let cat = data.category { self.selectedCategory = cat }
                    if let currency = data.currency {
                        if currency.contains("CNY") { self.location = .cn }
                        else if currency.contains("USD") { self.location = .us }
                        else if currency.contains("HKD") { self.location = .hk }
                        else if currency.contains("JPY") { self.location = .jp }
                        else if currency.contains("TWD") { self.location = .tw }
                        else if currency.contains("NZD") { self.location = .nz }
                        else if currency.contains("EUR") { self.location = .other }
                        else if currency.contains("GBP") { self.location = .uk }
                        else if currency.contains("MOP") { self.location = .mo }
                    }
                }
            }
        }
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

        if card.rewardType == .points {
            rewardPreview = nil
            Task {
                let pointValue = await resolvePointValueInCardCurrency(for: card)
                let result = card.calculateCappedPoints(
                    amount: finalAmount,
                    category: selectedCategory,
                    location: location,
                    date: date,
                    paymentMethod: paymentMethod,
                    pointValueInCardCurrency: pointValue,
                    transactionToExclude: transactionToEdit
                )

                let theoreticalRate = card.getRate(for: selectedCategory, location: location, payment: paymentMethod)
                let theoreticalValue = finalAmount * theoreticalRate
                let theoreticalPoints = pointValue > 0 ? Int(floor(theoreticalValue / pointValue)) : 0
                let isCapped = result.points < theoreticalPoints

                await MainActor.run {
                    rewardPreview = RewardPreview(value: result.value, points: result.points, isCapped: isCapped)
                }
            }
        } else {
            let cashback = card.calculateCappedCashback(
                amount: finalAmount,
                category: selectedCategory,
                location: location,
                date: date,
                paymentMethod: paymentMethod,
                transactionToExclude: transactionToEdit
            )

            let theoreticalRate = card.getRate(for: selectedCategory, location: location, payment: paymentMethod)
            let theoretical = finalAmount * theoreticalRate
            let isCapped = cashback < (theoretical - 0.01)
            rewardPreview = RewardPreview(value: cashback, points: 0, isCapped: isCapped)
        }
    }

    // v1 近似：积分价值统一折算到卡主币种，副币种入账的交易也按主币种估值 (待后续跟进)
    private func resolvePointValueInCardCurrency(for card: CreditCard) async -> Double {
        guard let pointProgram = card.pointProgram else { return 0 }
        let pointRegion = pointProgram.valueCurrencyCode
        let cardRegion = card.issueRegion
        if pointRegion == cardRegion {
            return pointProgram.pointValue
        }
        let rates = await CurrencyService.getRates(base: pointRegion.currencyCode)
        if let rate = rates[cardRegion.currencyCode], rate > 0 {
            return pointProgram.pointValue * rate
        }
        return pointProgram.pointValue
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

            var finalCashback: Double = 0
            var pointsEarned: Int = 0

            if card.rewardType == .points {
                let pointValue = await resolvePointValueInCardCurrency(for: card)
                let result = card.calculateCappedPoints(
                    amount: billingDouble,
                    category: selectedCategory,
                    location: location,
                    date: date,
                    paymentMethod: paymentMethod,
                    pointValueInCardCurrency: pointValue,
                    transactionToExclude: transactionToEdit
                )
                finalCashback = result.value
                pointsEarned = result.points
            } else {
                finalCashback = card.calculateCappedCashback(
                    amount: billingDouble,
                    category: selectedCategory,
                    location: location,
                    date: date,
                    paymentMethod: paymentMethod,
                    transactionToExclude: transactionToEdit
                )
            }

            let nominalRate = card.getRate(for: selectedCategory, location: location, payment: paymentMethod)
            let billingCode = resolvedBillingRegion(cards: cards).currencyCode

            if let t = transactionToEdit {
                // --- 编辑模式 ---
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
                context.insert(newTransaction)

                if card.transactions == nil {
                    card.transactions = [newTransaction]
                } else {
                    card.transactions?.append(newTransaction)
                }
            }

            try? context.save()
        }
    }
}
