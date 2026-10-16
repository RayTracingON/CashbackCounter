import XCTest
import UIKit
@testable import CashbackCounter

/// 卡面文字白字/黑字的选择规则。
///
/// 背景：CreditCardView 以前把文字写死成白色，白金卡、金卡、Apple Card 上卡号看不清；
/// 卡面图又会把渐变整个盖住，所以有图的卡必须按图来判断，不能只看 `colors`。
/// 这里锁住两件事：选色规则本身，以及卡面图采样确实落在卡号所在的左下角。
final class CardTextContrastTests: XCTestCase {

    private func rgb(_ hex: String) -> SIMD3<Double> {
        let v = Int(hex, radix: 16)!
        return SIMD3(Double((v >> 16) & 0xFF) / 255,
                     Double((v >> 8) & 0xFF) / 255,
                     Double(v & 0xFF) / 255)
    }

    // MARK: - 规则

    func testRelativeLuminance_referenceValues() {
        XCTAssertEqual(CardTextContrast.relativeLuminance(red: 1, green: 1, blue: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(CardTextContrast.relativeLuminance(red: 0, green: 0, blue: 0), 0, accuracy: 1e-9)
        // #777777 ≈ 0.184，WCAG 里常用的中灰参考值
        let gray = Double(0x77) / 255
        XCTAssertEqual(CardTextContrast.relativeLuminance(red: gray, green: gray, blue: gray), 0.184, accuracy: 0.001)
    }

    func testChosenInk_alwaysMeetsAAOnSolidBackgrounds() {
        // 纯白/纯黑二选一：任何纯色背景上，选中的那种对比度都应 ≥ 4.5，且就是两者中更好的那个
        for v in stride(from: 0.0, through: 1.0, by: 0.01) {
            let l = CardTextContrast.relativeLuminance(red: v, green: v, blue: v)
            let white = CardTextContrast.contrastRatio(1, l)
            let black = CardTextContrast.contrastRatio(0, l)
            let ink = CardTextContrast.ink(forBackgroundLuminances: [l])
            let chosen = ink == .light ? white : black
            XCTAssertEqual(chosen, max(white, black), accuracy: 1e-9, "gray \(v)")
            XCTAssertGreaterThanOrEqual(chosen, 4.5, "gray \(v)")
        }
    }

    func testEmptySamples_keepWhiteText() {
        XCTAssertEqual(CardTextContrast.ink(forBackgroundLuminances: []), .light)
        XCTAssertEqual(CardTextContrast.ink(gradient: []), .light)
    }

    // MARK: - 渐变

    func testDarkGradients_keepWhiteText() {
        // Sapphire Reserve、Marriott Boundless（深蓝→珊瑚，终点很亮但卡号那段仍偏暗）、HSBC Elite
        for (a, b) in [("12141C", "6E6555"), ("17304F", "C96A52"), ("0D0D0F", "3B4149")] {
            XCTAssertEqual(CardTextContrast.ink(gradient: [rgb(a), rgb(b)]), .light, "\(a)→\(b)")
        }
    }

    func testLightGradients_switchToBlackText() {
        // Apple Card、AMEX Gold、AMEX Platinum 的实卡原色 —— 白字下对比度都不到 3
        for (a, b) in [("F5F5F7", "F8D347"), ("A39458", "E0CA79"), ("D5D8DA", "B9BABC")] {
            XCTAssertEqual(CardTextContrast.ink(gradient: [rgb(a), rgb(b)]), .dark, "\(a)→\(b)")
        }
    }

    func testGreyToSilver_blackTextOnCardNumber() {
        // Capital One Quicksilver：灰→浅银。黑字时卡号那段 5.3、左上角图标 4.1；
        // 图标是图形元素只要 3:1，所以黑字两处都达标。白字的话卡号只剩 2.8
        XCTAssertEqual(CardTextContrast.ink(gradient: [rgb("5E6670"), rgb("B8BEC4")]), .dark)
    }

    func testGradientInterpolation_evenlySpacedStops() {
        let two = CardTextContrast.color(in: [SIMD3(0, 0, 0), SIMD3(1, 1, 1)], at: 0.25)
        XCTAssertEqual(two.x, 0.25, accuracy: 1e-9)
        // 三个色标时 0.75 落在第二段正中间
        let three = CardTextContrast.color(in: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)], at: 0.75)
        XCTAssertEqual(three.x, 1, accuracy: 1e-9)
        XCTAssertEqual(three.y, 0.5, accuracy: 1e-9)
    }

    // MARK: - 卡面图

    /// 标准卡比例的图：整体一种颜色，只有卡号所在的左下角换成另一种
    private func cardImage(body: UIColor, cardNumberArea: UIColor,
                           size: CGSize = CGSize(width: 856, height: 540)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            body.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            cardNumberArea.setFill()
            ctx.fill(CGRect(x: 0, y: size.height * 0.7, width: size.width * 0.6, height: size.height * 0.3))
        }
    }

    func testImage_samplesTheCardNumberCorner() {
        // 整张黑、只有左下角白 → 卡号压在白底上，必须黑字；反过来则白字
        XCTAssertEqual(CardTextContrast.ink(cardImage: cardImage(body: .black, cardNumberArea: .white)), .dark)
        XCTAssertEqual(CardTextContrast.ink(cardImage: cardImage(body: .white, cardNumberArea: .black)), .light)
    }

    func testImage_lightSilverFace_getsBlackText() {
        // Platinum 的情况：渐变配得很暗，但真正显示的是浅银色卡面图 —— 以图为准
        let silver = UIColor(red: 0.73, green: 0.73, blue: 0.74, alpha: 1)
        XCTAssertEqual(CardTextContrast.ink(cardImage: cardImage(body: silver, cardNumberArea: silver)), .dark)
    }

    func testImage_respectsEXIFOrientation() {
        // 用户拍的卡面照片：像素是转过 180° 的，靠 EXIF 方向显示成正的。
        // 显示出来卡号那角是白的，所以应选黑字；若直接读 CGImage 像素就会读到黑角、选错
        let upright = cardImage(body: .black, cardNumberArea: .white)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rotatedPixels = UIGraphicsImageRenderer(size: upright.size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: upright.size.width, y: upright.size.height)
            ctx.cgContext.rotate(by: .pi)
            upright.draw(at: .zero)
        }
        let photo = UIImage(cgImage: rotatedPixels.cgImage!, scale: 1, orientation: .down)
        XCTAssertEqual(CardTextContrast.ink(cardImage: photo), .dark)
    }

    func testImage_fullyTransparentRegion_fallsBackToGradient() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let clear = UIGraphicsImageRenderer(size: CGSize(width: 856, height: 540), format: format).image { _ in }
        XCTAssertNil(CardTextContrast.ink(cardImage: clear))
    }

    func testImageRect_aspectFillCropping() {
        let region = CardTextContrast.cardNumberRegion
        // 和卡片同比例的图不裁切，直接按比例映射
        let same = CardTextContrast.imageRect(forCardRegion: region, imageSize: CGSize(width: 1586, height: 1000))
        XCTAssertEqual(same.minX, 1586 * region.minX, accuracy: 0.5)
        XCTAssertEqual(same.minY, 1000 * region.minY, accuracy: 0.5)
        // 比卡片宽得多的图左右各裁掉一截：卡号区域应往图的中间挪
        let wide = CardTextContrast.imageRect(forCardRegion: region, imageSize: CGSize(width: 2000, height: 540))
        XCTAssertGreaterThan(wide.minX, 2000 * region.minX)
    }
}
