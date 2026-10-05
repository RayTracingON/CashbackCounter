import XCTest
import SwiftData
import UIKit
@testable import CashbackCounter

private typealias Category = CashbackCounter.Category
private typealias Draft = BatchReceiptImportViewModel.Draft

@MainActor
final class BatchReceiptImportViewModelTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema([CreditCard.self, Transaction.self, Point.self, PointAdjustment.self, Income.self])
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        let config = ModelConfiguration(url: url, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeCard(endNum: String, issueRegion: Region = .hk, localBaseCap: Double = 0) -> CreditCard {
        let card = CreditCard(
            bankName: "TestBank",
            type: "Card\(endNum)",
            endNum: endNum,
            colorHexes: ["FF0000"],
            defaultRate: 0.01,
            specialRates: [:],
            issueRegion: issueRegion,
            localBaseCap: localBaseCap
        )
        context.insert(card)
        return card
    }

    private func makeDraft(status: BatchReceiptImportViewModel.DraftStatus = .recognized,
                           merchant: String = "Test Merchant",
                           amount: Double? = 100,
                           location: Region? = .hk,
                           cardLast4: String? = nil) -> Draft {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        var draft = Draft(imageData: image.jpegData(compressionQuality: 0.8)!, thumbnail: image)
        draft.status = status
        draft.merchant = merchant
        draft.amount = amount
        draft.location = location
        draft.cardLast4 = cardLast4
        return draft
    }

    private func fetchTransactions() throws -> [Transaction] {
        try context.fetch(FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.amount)]))
    }

    // MARK: - Card Resolution

    /// 每张收据只按自己小票上的卡号尾号匹配，对不上就不猜
    func testCardResolution_MatchesEachReceiptByItsOwnLast4() {
        let cards = [makeCard(endNum: "1111"), makeCard(endNum: "2222")]
        let vm = BatchReceiptImportViewModel()

        XCTAssertEqual(vm.card(for: makeDraft(cardLast4: "1111"), cards: cards)?.endNum, "1111")
        XCTAssertEqual(vm.card(for: makeDraft(cardLast4: "2222"), cards: cards)?.endNum, "2222")
        XCTAssertNil(vm.card(for: makeDraft(cardLast4: "9999"), cards: cards), "尾号对不上卡包里的卡时不回落到任何卡")
        XCTAssertNil(vm.card(for: makeDraft(cardLast4: nil), cards: cards), "没识别出尾号时不回落到任何卡")
    }

    func testReadyCount_ExcludesUnmatchedAndFailed() {
        let cards = [makeCard(endNum: "1111")]
        let vm = BatchReceiptImportViewModel(drafts: [
            makeDraft(cardLast4: "1111"),
            makeDraft(cardLast4: "9999"),
            makeDraft(status: .failed, amount: nil, cardLast4: "1111")
        ])

        XCTAssertEqual(vm.readyCount(cards: cards), 1)
    }

    func testRegion_FallsBackToCardIssueRegionWhenCurrencyUnknown() {
        let cards = [makeCard(endNum: "1111", issueRegion: .jp)]
        let vm = BatchReceiptImportViewModel()

        XCTAssertEqual(vm.region(for: makeDraft(location: nil, cardLast4: "1111"), cards: cards), .jp)
        XCTAssertEqual(vm.region(for: makeDraft(location: .us), cards: cards), .us)
    }

    // MARK: - Save

    func testSaveRecognized_SavesMatchedAndKeepsUnmatchedOrFailedDrafts() async throws {
        let cards = [makeCard(endNum: "1111"), makeCard(endNum: "2222")]
        let unmatched = makeDraft(merchant: "Unmatched", amount: 300, cardLast4: "9999")
        let failed = makeDraft(status: .failed, amount: nil)
        let vm = BatchReceiptImportViewModel(drafts: [
            makeDraft(merchant: "Matched", amount: 100, cardLast4: "2222"),
            makeDraft(merchant: "", amount: 200, cardLast4: "1111"),
            unmatched,
            failed
        ])

        let saved = await vm.saveRecognized(cards: cards, context: context)

        XCTAssertEqual(saved, 2)
        XCTAssertEqual(vm.drafts.map(\.id), [unmatched.id, failed.id], "没匹配到卡、没识别出金额的都留在列表里等手动补充")

        let transactions = try fetchTransactions()
        XCTAssertEqual(transactions.count, 2)
        XCTAssertEqual(transactions[0].merchant, "Matched")
        XCTAssertEqual(transactions[0].card?.endNum, "2222")
        XCTAssertEqual(transactions[1].merchant, String.loc("未知商户"), "没识别出商户时用占位名")
        XCTAssertEqual(transactions[1].card?.endNum, "1111")
        XCTAssertNotNil(transactions[0].receiptData, "收据图片要随账单保存")
        XCTAssertEqual(transactions[0].cashbackamount, 1, accuracy: 0.0001)
    }

    /// 同一批里的多张收据要互相计入返现上限：后保存的要能看到前面刚存的
    func testSaveRecognized_AppliesCapAcrossBatch() async throws {
        let card = makeCard(endNum: "1111", localBaseCap: 10)
        let vm = BatchReceiptImportViewModel(drafts: [
            makeDraft(amount: 600, cardLast4: "1111"),
            makeDraft(amount: 700, cardLast4: "1111")
        ])

        _ = await vm.saveRecognized(cards: [card], context: context)

        let transactions = try fetchTransactions()
        XCTAssertEqual(transactions.count, 2)
        XCTAssertEqual(transactions[0].cashbackamount, 6, accuracy: 0.0001)
        XCTAssertEqual(transactions[1].cashbackamount, 4, accuracy: 0.0001, "第二张只剩 4 的额度")
    }

    func testSaveRecognized_NoCardsSavesNothing() async throws {
        let vm = BatchReceiptImportViewModel(drafts: [makeDraft(cardLast4: "1111")])

        let saved = await vm.saveRecognized(cards: [], context: context)

        XCTAssertEqual(saved, 0)
        XCTAssertEqual(vm.drafts.count, 1)
        XCTAssertTrue(try fetchTransactions().isEmpty)
    }
}
