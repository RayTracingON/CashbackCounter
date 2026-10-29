//
//  AdaptiveLayout.swift
//  CashbackCounter
//
//  宽屏（iPad、iPhone Duo 内屏）和 Duo 竖排工具栏的通用适配。
//

import SwiftUI

extension View {
    /// 宽屏上把滚动页面的内容收到 `DesignConstants.readableContentWidth` 并居中；
    /// 比这个宽度窄的窗口（所有 iPhone、Duo 外屏、iPad 窄分屏）原样铺满。
    ///
    /// 挂在 ScrollView **里面**的内容上：ScrollView 本身仍然铺满，宽屏两侧的留白也能拖动滚动。
    func readableContentWidth() -> some View {
        frame(maxWidth: DesignConstants.readableContentWidth)
            .frame(maxWidth: .infinity)
    }

    /// 这一页的导航栏 / 工具栏保持横排。
    ///
    /// iPhone Duo 合上用外屏时，系统默认把 sheet 的导航栏竖着放到屏幕侧边，而竖排栏只放
    /// 有图标的按钮 —— 我们编辑页里的「取消」「保存」「提交」都是纯文字，竖排时会被挤进溢出菜单，
    /// 得多点一下才找得到保存。表单页横排本来就够用，这里直接退回横排。
    ///
    /// 挂在 NavigationStack 里面的页面内容上（和 `.toolbar` 同一层）：导航栈按栈顶页面的设置决定横竖。
    @ViewBuilder
    func prefersHorizontalToolbar() -> some View {
        if #available(iOS 27.1, *) {
            toolbarVerticalBehavior(.disabled)
        } else {
            self
        }
    }
}
