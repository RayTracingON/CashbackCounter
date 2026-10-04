import XCTest
import UIKit
@testable import CashbackCounter

@MainActor
final class AddTransactionViewModelTests: XCTestCase {

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    /// 截屏/拍照入口已预填商户金额：进入页面时的自动识别不应覆盖
    func testAnalyzeReceipt_SkipsWhenFormAlreadyFilled() {
        let vm = AddTransactionViewModel(image: makeImage(), prefillMerchant: "山姆会员店", prefillAmount: 486.5)

        vm.analyzeReceipt(cards: [])

        XCTAssertFalse(vm.isAnalyzing)
    }

    /// 回归：首张小票识别填好表单后删图、重新上传，必须再次触发识别
    func testAnalyzeReceipt_ForceReanalyzesAfterReupload() {
        let vm = AddTransactionViewModel()
        vm.merchant = "上一张小票的商户"
        vm.amount = "12.00"

        vm.receiptImage = nil
        vm.cancelReceiptAnalysis()
        vm.receiptImage = makeImage()
        vm.analyzeReceipt(cards: [], force: true)

        XCTAssertTrue(vm.isAnalyzing)
        vm.cancelReceiptAnalysis()
    }

    func testCancelReceiptAnalysis_ClearsAnalyzingState() {
        let vm = AddTransactionViewModel(image: makeImage())
        vm.analyzeReceipt(cards: [])
        XCTAssertTrue(vm.isAnalyzing)

        vm.receiptImage = nil
        vm.cancelReceiptAnalysis()

        XCTAssertFalse(vm.isAnalyzing)
    }
}
