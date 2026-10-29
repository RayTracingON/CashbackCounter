//
//  DesignConstants.swift
//  CashbackCounter
//
//  统一设计常量系统 — 用于替代散落在各视图中的魔法数字。
//  使用动态值适配不同窗口尺寸：iPhone (SE ~ Pro Max)、iPhone Duo 内外屏、iPad（含分屏）。
//

import SwiftUI

enum DesignConstants {

    // MARK: - 窗口宽度（统一获取入口，兼容 iOS 26 弃用 UIScreen.main）

    /// 当前前台窗口的宽度。
    ///
    /// 量窗口而不是屏幕：iPad 分屏 / 台前调度下窗口只占屏幕的一部分，
    /// iPhone Duo 开合时 App 会在内外两块屏之间换来换去，屏幕宽度都说明不了 App 实际有多宽。
    private static var windowWidth: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let window = scene?.keyWindow ?? scene?.windows.first {
            return window.bounds.width
        }
        return 375 // fallback 默认值（iPhone SE 宽度）
    }

    /// 是否为小窗口（iPhone SE 等 375pt 及以下，或 iPad 上的窄分屏）。SE 正好是 375，之前写 `<` 把它排除在外了
    static var isCompact: Bool { windowWidth <= 375 }

    // MARK: - 圆角半径

    enum CornerRadius {
        /// 小元素：标签、badge、小按钮 (5pt)
        static let small: CGFloat = 5
        /// 中等元素：筛选器按钮、输入框 (8pt)
        static let medium: CGFloat = 8
        /// 大元素：卡片容器、弹窗 (12pt)
        static let large: CGFloat = 12
        /// 特大元素：趋势图卡片 (16pt)
        static let extraLarge: CGFloat = 16
        /// 药丸形状：积分卡片 (18pt)
        static let pill: CGFloat = 18
    }

    // MARK: - 间距 (动态适配不同屏幕宽度)

    enum Spacing {
        /// 水平边距 — 小屏 12pt，大屏 16pt
        static var horizontalPadding: CGFloat { DesignConstants.isCompact ? 12 : 16 }

        /// 列表项之间的间距
        static var listItemSpacing: CGFloat { DesignConstants.isCompact ? 10 : 15 }

        /// Section 之间的间距
        static var sectionSpacing: CGFloat { DesignConstants.isCompact ? 15 : 20 }

        /// 统计栏内部元素间距
        static var statsSpacing: CGFloat { DesignConstants.isCompact ? 10 : 15 }

        /// 筛选器 chip 之间的间距
        static let chipSpacing: CGFloat = 10

        /// 筛选器两侧留白
        static let chipEdgeInset: CGFloat = 16

        /// 底部按钮区域的底边距
        static var bottomPadding: CGFloat { DesignConstants.isCompact ? 40 : 50 }

        /// 底部按钮区域的水平边距
        static var bottomHorizontalPadding: CGFloat { DesignConstants.isCompact ? 24 : 30 }
    }

    // MARK: - 尺寸 (动态适配)

    enum Size {
        /// 卡面图片容器高度
        static var cardImageHeight: CGFloat { DesignConstants.isCompact ? 180 : 200 }

        /// 设置页 App 图标圆圈
        static var settingsIconCircle: CGFloat { DesignConstants.isCompact ? 70 : 80 }
        static var settingsIconFont: CGFloat { DesignConstants.isCompact ? 36 : 40 }

        /// 相机拍照按钮（外圈）
        static var cameraButtonOuter: CGFloat { DesignConstants.isCompact ? 60 : 70 }
        /// 相机拍照按钮（内圈）
        static var cameraButtonInner: CGFloat { DesignConstants.isCompact ? 50 : 60 }
        /// 相机两侧按钮
        static var cameraSideButton: CGFloat { DesignConstants.isCompact ? 50 : 60 }

        /// 拖拽提示图标
        static var dropIndicatorIcon: CGFloat { DesignConstants.isCompact ? 64 : 80 }
    }

    // MARK: - 卡片列表布局 (基于卡包页实际拿到的尺寸动态计算)

    /// 卡包堆叠列表的各项尺寸。
    ///
    /// 全部由卡包页自己的尺寸推出来（GeometryReader 量），不读屏幕：iPad 分屏 / 台前调度、
    /// iPhone Duo 开合时窗口会实时变大变小，按屏幕算的话卡片尺寸跟不上。
    struct CardList {
        /// 信用卡标准比例 (ISO/IEC 7810 ID-1: 85.6 × 53.98 mm ≈ 1.586)
        static let aspectRatio: CGFloat = 1.586

        /// 卡面最宽多少。iPad、Duo 内屏上照手机那样铺满整行的话，一张卡六百多点高，
        /// 一屏只叠得下两张；封顶在比 Pro Max 卡宽略大一点，多出的宽度两边留白
        static let maxCardWidth: CGFloat = 480

        /// 卡片两侧的水平留白（CreditCardView 自带 `.padding(.horizontal)`，系统默认 16pt）
        static let horizontalInset: CGFloat = 16

        /// 卡片列表首张卡片的顶部间距
        static let listTopPadding: CGFloat = 20

        /// 卡片 + 两侧留白的整列宽度；交易列表、关闭层都对齐这一列
        let columnWidth: CGFloat

        /// 单张卡片高度 — 由宽度 / 标准银行卡比例动态得出
        let cardHeight: CGFloat

        /// 未选中卡片隐藏到可视区域外的偏移量
        let detailPushDistance: CGFloat

        init(containerSize: CGSize) {
            let cardWidth = max(min(containerSize.width - Self.horizontalInset * 2, Self.maxCardWidth), 0)
            columnWidth = cardWidth + Self.horizontalInset * 2
            cardHeight = cardWidth / Self.aspectRatio
            detailPushDistance = containerSize.height
        }

        /// 卡片堆叠时，相邻卡片之间的垂直偏移（露出约 45% 的高度）
        var stackOffset: CGFloat { cardHeight * 0.45 }

        /// 选中卡片后，卡片停靠的顶部偏移
        var selectedTopInset: CGFloat { cardHeight * 0.55 }

        /// 底部占位区域需要的每张卡片高度贡献
        var placeholderPerCard: CGFloat { stackOffset + Self.listTopPadding }

        /// 交易列表距离顶部的偏移 — 留出刚好一张卡的空间
        var transactionListTopPadding: CGFloat { cardHeight + 10 }

        /// 关闭按钮区域高度 — 与卡片高度一致
        var closeOverlayHeight: CGFloat { cardHeight }
    }

    // MARK: - 宽屏阅读宽度

    /// 滚动页面内容的最大宽度。iPad、Duo 内屏横放时整行铺开，一行账单两头隔着大半个屏幕，
    /// 收到这个宽度居中；手机和 Duo 外屏都比它窄，不受影响
    static let readableContentWidth: CGFloat = 680

    // MARK: - 字体大小 (动态)

    enum FontSize {
        /// Toolbar 图标
        static var toolbarIcon: CGFloat { DesignConstants.isCompact ? 16 : 18 }
    }
}
