import XCTest
@testable import CashbackCounter
import Vision

final class OCRServiceTests: XCTestCase {

    // MARK: - simpleInferRegion Tests
    
    func testSimpleInferRegion_JP() {
        let texts = [
            "This is a test with JPY inside",
            "金額: 1000円",
            "お支払い合計",  // Contains 合計
            "料金: 100"
        ]
        
        for text in texts {
            XCTAssertEqual(OCRService.simpleInferRegion(from: text), .jp, "Should infer JP for text: \(text)")
        }
    }
    
    func testSimpleInferRegion_CN() {
        let texts = [
            "CNY 100",
            "RMB 50",
            "人民币 100元",
            "交易金额: 100" // Contains 交易 and 金额
        ]
        
        for text in texts {
            XCTAssertEqual(OCRService.simpleInferRegion(from: text), .cn, "Should infer CN for text: \(text)")
        }
    }

    func testSimpleInferRegion_US() {
        let texts = [
            "Total USD 100",
            "USA shop",
            "US$ 50"
        ]
        
        for text in texts {
            XCTAssertEqual(OCRService.simpleInferRegion(from: text), .us, "Should infer US for text: \(text)")
        }
    }

    func testSimpleInferRegion_HK() {
        let texts = [
            "HKD 100",
            "HK$ 50",
            "Welcome to HONG KONG"
        ]
        
        for text in texts {
            XCTAssertEqual(OCRService.simpleInferRegion(from: text), .hk, "Should infer HK for text: \(text)")
        }
    }

    func testSimpleInferRegion_TW() {
        let texts = [
            "TWD 100",
            "NT$ 50",
            "TAIPEI CITY",
            "台灣好行"
        ]
        
        for text in texts {
            XCTAssertEqual(OCRService.simpleInferRegion(from: text), .tw, "Should infer TW for text: \(text)")
        }
    }
    
    func testSimpleInferRegion_UK() {
        let texts = [
            "GBP 100",
            "£ 50",
            "Welcome to UK"
        ]
        
        for text in texts {
            XCTAssertEqual(OCRService.simpleInferRegion(from: text), .uk, "Should infer UK for text: \(text)")
        }
    }
    
    func testSimpleInferRegion_Other_EUR() {
        let texts = [
            "EUR 100",
            "EURO 50",
            "€ 50"
        ]
        
        for text in texts {
            XCTAssertEqual(OCRService.simpleInferRegion(from: text), .other, "Should infer .other for text: \(text)")
        }
    }

    func testSimpleInferRegion_Unknown() {
        let text = "Just some random English text without currency or region keywords"
        XCTAssertNil(OCRService.simpleInferRegion(from: text))
    }

    // MARK: - cgImageOrientation Tests

    func testCGImageOrientation() {
        XCTAssertEqual(OCRService.cgImageOrientation(from: .up), .up)
        XCTAssertEqual(OCRService.cgImageOrientation(from: .down), .down)
        XCTAssertEqual(OCRService.cgImageOrientation(from: .left), .left)
        XCTAssertEqual(OCRService.cgImageOrientation(from: .right), .right)
        XCTAssertEqual(OCRService.cgImageOrientation(from: .upMirrored), .upMirrored)
        XCTAssertEqual(OCRService.cgImageOrientation(from: .downMirrored), .downMirrored)
        XCTAssertEqual(OCRService.cgImageOrientation(from: .leftMirrored), .leftMirrored)
        XCTAssertEqual(OCRService.cgImageOrientation(from: .rightMirrored), .rightMirrored)
    }
}
