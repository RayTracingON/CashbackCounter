//
//  CardTextContrast.swift
//  CashbackCounter
//

import UIKit

/// 卡面上的文字用白字还是黑字。
///
/// CreditCardView 原来把文字层写死成白色，白金、金卡、Apple Card 这类浅色卡面上卡号会糊掉。
/// 现在按文字**实际压在**的那块背景来选：有卡面图就看图上卡号所在的左下角，
/// 没有图就在渐变上按图标和卡号的位置采样。
///
/// 规则：每个采样点按压在上面的元素要求打分（对比度 ÷ 要求的对比度），白字、黑字各取最差的一点，
/// 选余量更大的一种。卡号是正文，按 WCAG 1.4.3 要 4.5:1；左上的非接触图标是图形，按 1.4.11 要 3:1。
/// 纯白/纯黑二选一时，任何单一颜色的背景都能保底约 4.58:1。
///
/// ⚠️ tools/cardeditor 的 server.py（校验）和 index.html（预览）实现了同一套规则，改这里要同步。
nonisolated enum CardTextContrast {

    enum Ink: Equatable, Sendable {
        /// 白字
        case light
        /// 黑字
        case dark
    }

    /// 一个采样点：背景的相对亮度，和压在这里的元素要求的对比度
    struct Sample: Sendable {
        let luminance: Double
        let required: Double
    }

    /// 渐变上的采样点：位置（0 = 左上起点，1 = 右下终点）和该处元素的要求。
    ///
    /// 卡片比例 1.586、渐变从左上角拉到右下角：左上的非接触图标约在 0.1，
    /// 左下的卡号横跨约 0.28–0.64。
    static let gradientSamples: [(position: Double, required: Double)] = [
        (0.10, 3.0),                             // 非接触图标：图形元素
        (0.30, 4.5), (0.45, 4.5), (0.60, 4.5),   // 卡号：正文
    ]

    /// 卡号在卡面上的区域（相对卡片宽高）。卡片内边距 25pt、卡号 .subheadline，
    /// 从 SE 宽度到 Pro Max 宽度都落在这个范围里。
    static let cardNumberRegion = CGRect(x: 0.06, y: 0.79, width: 0.46, height: 0.12)

    /// 与 DesignConstants.CardList 一致的卡片宽高比；卡面图按 aspect fill 居中裁切显示。
    static let cardAspectRatio: CGFloat = 1.586

    // MARK: - 规则

    /// gamma 编码的 sRGB 分量（0…1）→ WCAG 相对亮度
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double {
            let c = min(max(c, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// 白字、黑字各自在所有采样点里「对比度 ÷ 要求」的最小值，返回余量更大的那种；打平时保持白字。
    static func ink(for samples: [Sample]) -> Ink {
        guard let white = samples.map({ contrastRatio(1, $0.luminance) / $0.required }).min(),
              let black = samples.map({ contrastRatio(0, $0.luminance) / $0.required }).min()
        else { return .light }
        return black > white ? .dark : .light
    }

    /// 只压着正文（卡号）的背景：每个点都按 4.5:1 要求
    static func ink(forBackgroundLuminances luminances: [Double]) -> Ink {
        ink(for: luminances.map { Sample(luminance: $0, required: 4.5) })
    }

    // MARK: - 渐变

    /// `stops` 是 gamma 编码的 sRGB 颜色，按 `Gradient(colors:)` 的方式等距分布；
    /// SwiftUI 渐变默认（`.device`）就在这个空间里线性插值。
    static func ink(gradient stops: [SIMD3<Double>]) -> Ink {
        ink(for: gradientSamples.map { sample in
            let c = color(in: stops, at: sample.position)
            return Sample(luminance: relativeLuminance(red: c.x, green: c.y, blue: c.z),
                          required: sample.required)
        })
    }

    static func color(in stops: [SIMD3<Double>], at t: Double) -> SIMD3<Double> {
        guard let first = stops.first else { return SIMD3(repeating: 0) }
        guard stops.count > 1 else { return first }
        let position = min(max(t, 0), 1) * Double(stops.count - 1)
        let i = min(Int(position), stops.count - 2)
        return stops[i] + (stops[i + 1] - stops[i]) * (position - Double(i))
    }

    // MARK: - 卡面图

    /// 按卡面图上卡号那块区域判断；区域几乎全透明、取不到像素时返回 nil，由调用方退回渐变判断。
    static func ink(cardImage image: UIImage) -> Ink? {
        let luminances = cardNumberLuminances(in: image)
        return luminances.isEmpty ? nil : ink(forBackgroundLuminances: luminances)
    }

    /// 卡号区域映射到图片上的矩形（图片 point 坐标，左上为原点）。
    /// 卡面图在视图里是 aspect fill + 居中裁切，所以先算出图片被裁掉了多少。
    static func imageRect(forCardRegion region: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .null }
        let view = CGSize(width: cardAspectRatio, height: 1)
        let scale = max(view.width / imageSize.width, view.height / imageSize.height)
        let origin = CGPoint(x: (view.width - imageSize.width * scale) / 2,
                             y: (view.height - imageSize.height * scale) / 2)
        let rect = CGRect(x: (region.minX * view.width - origin.x) / scale,
                          y: (region.minY * view.height - origin.y) / scale,
                          width: region.width * view.width / scale,
                          height: region.height * view.height / scale)
        return rect.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// 卡号区域横向切成几段，各段的平均相对亮度。透明像素（圆角外那部分）不计入。
    static func cardNumberLuminances(in image: UIImage, segments: Int = 4) -> [Double] {
        let rect = imageRect(forCardRegion: cardNumberRegion, imageSize: image.size)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return [] }

        // 把这块区域画进一个很小的位图：每段 8×4 像素，求平均足够了
        let width = segments * 8, height = 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }

        // 翻成 UIKit 的 y 向下坐标，再让 rect 铺满整个位图。
        // 用 UIImage.draw 而不是直接画 CGImage：用户拍的卡面照片带 EXIF 方向，像素本身是转过的
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / rect.width, y: -CGFloat(height) / rect.height)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.interpolationQuality = .high
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        UIGraphicsPopContext()

        guard let data = context.data else { return [] }
        let bytesPerRow = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        let segmentWidth = width / segments

        return (0..<segments).compactMap { segment in
            var sum = 0.0, count = 0
            for y in 0..<height {
                for x in (segment * segmentWidth)..<((segment + 1) * segmentWidth) {
                    let p = y * bytesPerRow + x * 4
                    let alpha = Double(pixels[p + 3]) / 255
                    guard alpha >= 0.5 else { continue }
                    // premultiplied → 还原真实颜色
                    sum += relativeLuminance(red: Double(pixels[p]) / 255 / alpha,
                                             green: Double(pixels[p + 1]) / 255 / alpha,
                                             blue: Double(pixels[p + 2]) / 255 / alpha)
                    count += 1
                }
            }
            return count > 0 ? sum / Double(count) : nil
        }
    }
}
