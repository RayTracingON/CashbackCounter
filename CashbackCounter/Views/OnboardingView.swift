//
//  OnboardingView.swift
//  CashbackCounter
//
//  新手导览的蒙层：压暗真实界面，只挖空要点的那个控件，旁边一个气泡说明。
//  走到哪一步、高亮哪个控件由 OnboardingTour（ViewModels/）决定，这里只负责画。
//
//  接线方式：
//  - 可高亮的控件挂 `.tourTarget(.xxx)`，把自己在窗口里的位置报给导览；
//  - 导览会经过的每层界面（主界面 TabView、模板列表 sheet、添加卡片 sheet）根部
//    挂 `.tourOverlayHost(.xxx)`，蒙层就画在那一层上。
//

import SwiftData
import SwiftUI

extension View {
    /// 标记一个可以被导览高亮的真实控件
    func tourTarget(_ target: TourTarget) -> some View {
        modifier(TourTargetModifier(target: target))
    }

    /// 在这一层界面上画导览蒙层。
    ///
    /// 只挂在界面根部：同一个视图层级里挂两个宿主，会叠出两层蒙层。
    func tourOverlayHost(_ host: TourHost) -> some View {
        overlay { TourOverlay(host: host) }
    }

    /// 挂在每个标签页的内容上，告诉导览 TabBar 的顶边在哪（见 `OnboardingTour.tabBarTop`）。
    ///
    /// 标签页内容的安全区底边正好就是 TabBar 的顶边：底部对齐的 overlay 默认守安全区，
    /// 不管内容本身是铺满全屏（NavigationStack）还是只占安全区（拍一笔页），量到的都是同一条线。
    func tourTabContent() -> some View {
        overlay(alignment: .bottom) {
            Color.clear
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).minY
                } action: { y in
                    OnboardingTour.shared.updateTabBarTop(y)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct TourTargetModifier: ViewModifier {
    let target: TourTarget

    func body(content: Content) -> some View {
        content
            // 用 .global 而不是 anchorPreference：工具栏按钮的 preference 冒不到页面上，
            // sheet 里的也冒不到根视图。窗口坐标在哪一层都量得出来，宿主再换算回自己的坐标系。
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                OnboardingTour.shared.updateFrame(frame, for: target)
            }
            .onAppear { OnboardingTour.shared.setVisible(true, target: target) }
            .onDisappear { OnboardingTour.shared.setVisible(false, target: target) }
    }
}

extension TourTarget {
    /// 列表里的一整行。只框住行里的文字会显得很局促，挖空范围按整行的卡片背景算
    fileprivate var isListRow: Bool {
        switch self {
        case .cardLastFour, .screenshotShortcut, .shortcutGuide, .bankSync: true
        default: false
        }
    }
}

// MARK: - 宿主

private struct TourOverlay: View {
    let host: TourHost

    @State private var tour = OnboardingTour.shared

    var body: some View {
        ZStack {
            if host == .main {
                CardPresenceReporter()
            }
            if let step = tour.step, step.host == host {
                TourStepLayer(step: step, tour: tour, host: host)
                    .transition(.opacity)
            }
        }
    }
}

/// 把「卡包里有没有卡」实时告诉导览（见 `OnboardingTour.hasCards`）。
///
/// 放在主界面宿主里而不是 ContentView 上：只取一条的 @Query 很便宜，
/// 挂在 ContentView 上的话，任何一张卡变动都会让整个 TabView 重算一遍 body。
private struct CardPresenceReporter: View {
    @Query private var cards: [CreditCard]

    init() {
        var descriptor = FetchDescriptor<CreditCard>()
        descriptor.fetchLimit = 1
        _cards = Query(descriptor)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // iCloud 同步可能在欢迎卡片亮着的时候才把卡带回来，所以要一直跟着变
            .onChange(of: cards.isEmpty, initial: true) { _, isEmpty in
                OnboardingTour.shared.hasCards = !isEmpty
            }
    }
}

/// 一个被挖空的洞，坐标已换算到宿主自己的坐标系
private struct TourHole: Equatable {
    var rect: CGRect
    var cornerRadius: CGFloat

    var path: Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
    }
}

private struct TourStepLayer: View {
    let step: TourStep
    let tour: OnboardingTour
    let host: TourHost

    /// 点了蒙层（而不是高亮处）时让气泡弹一下，提醒该点哪儿
    @State private var nudge = 0
    /// 目标控件迟迟没出现（比如被滚出了屏幕）时，退而把气泡居中放，保证用户还能跳过或退出
    @State private var showsFallback = false

    var body: some View {
        // 外层只用来量安全区（含弹出的键盘）：铺满全屏的内层读到的 safeAreaInsets 恒为 0
        GeometryReader { safeArea in
            let insets = safeArea.safeAreaInsets
            GeometryReader { proxy in
                let size = proxy.size

                switch step.style {
                case .card:
                    cardLayer(insets: insets)

                case .hint:
                    VStack {
                        Spacer()
                        bubble(arrow: nil)
                            .frame(maxWidth: 420)
                            .padding(.horizontal, 16)
                            .padding(.bottom, hintBottomPadding(in: proxy, insets: insets))
                    }
                    .frame(width: size.width, height: size.height)

                case .spotlight:
                    let holes = holes(in: proxy)
                    ZStack {
                        SpotlightDimming(holes: holes, size: size) { nudge += 1 }

                        if let anchor = holes.map(\.rect).reduce(nil, { $0?.union($1) ?? $1 }) {
                            // 两个分开的洞（相册 + 手动记账）时，箭头指向两者中点会正好戳在没高亮的快门上
                            positionedBubble(pointingAt: anchor, showsArrow: holes.count == 1, size: size, insets: insets)
                        } else if showsFallback {
                            bubble(arrow: nil)
                                .frame(maxWidth: 420)
                                .padding(.horizontal, 16)
                                .frame(width: size.width, height: size.height)
                        }
                    }
                }
            }
            .ignoresSafeArea()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: nudge)
        .task(id: step) {
            showsFallback = false
            try? await Task.sleep(for: .milliseconds(800))
            showsFallback = true
        }
    }

    /// 提示卡离（铺满全屏的）宿主底边的距离。
    ///
    /// 主界面底部压着 TabBar，得让出它的高度，不然会把标签栏盖住。
    /// 不能按「安全区 + 固定值」估：有 Home 键的机型安全区是 0，TabBar 却一样高。
    private func hintBottomPadding(in proxy: GeometryProxy, insets: EdgeInsets) -> CGFloat {
        let gap: CGFloat = 12
        guard host == .main else { return insets.bottom + gap }
        guard let tabBarTop = tour.tabBarTop else {
            // 还没量到 TabBar（理论上标签页一出现就有了），按全面屏的 TabBar 高度估
            return insets.bottom + 60
        }
        return max(proxy.frame(in: .global).maxY - tabBarTop, insets.bottom) + gap
    }

    // MARK: 挖空

    private func holes(in proxy: GeometryProxy) -> [TourHole] {
        let origin = proxy.frame(in: .global).origin
        let width = proxy.size.width

        var holes: [TourHole] = []
        for target in step.targets {
            // 有一个目标还没上屏就先不画：只挖一半的洞会指错地方
            guard let frame = tour.frame(for: target) else { return [] }
            let local = frame.offsetBy(dx: -origin.x, dy: -origin.y)
            if target.isListRow {
                // inset grouped 列表的左右边距跟系统布局边距走：Plus/Max 宽度（≥414pt）是 20pt，
                // 其余 iPhone 是 16pt；行内容上下各有约 11pt 的内边距
                let margin: CGFloat = width >= 414 ? 20 : 16
                let rect = CGRect(x: margin, y: local.minY - 11, width: width - margin * 2, height: local.height + 22)
                holes.append(TourHole(rect: rect, cornerRadius: 16))
            } else {
                // 按钮挖成胶囊/圆：相机的圆按钮、工具栏的玻璃按钮都是这个形状
                let rect = local.insetBy(dx: -8, dy: -8)
                holes.append(TourHole(rect: rect, cornerRadius: min(rect.width, rect.height) / 2))
            }
        }

        if step.mergesTargets, let first = holes.first {
            let rect = holes.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            return [TourHole(rect: rect, cornerRadius: first.cornerRadius)]
        }
        return holes
    }

    // MARK: 气泡

    private func bubble(arrow: BubbleArrow?) -> some View {
        TourBubble(
            step: step,
            canSkip: tour.skipDestination != nil,
            arrow: arrow,
            onPrimary: tour.advance,
            onSkip: tour.skipChapter,
            onClose: tour.end
        )
        .keyframeAnimator(initialValue: 1.0, trigger: nudge) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(1.04, duration: 0.12)
            SpringKeyframe(1.0, duration: 0.3)
        }
    }

    /// 气泡放在高亮处上方还是下方：哪边地方大放哪边，除非这一步指定了
    private func positionedBubble(pointingAt anchor: CGRect, showsArrow: Bool, size: CGSize, insets: EdgeInsets) -> some View {
        let bubbleWidth = min(size.width - 32, 420)
        let leading = (size.width - bubbleWidth) / 2
        let arrowX = min(max(anchor.midX - leading, 32), bubbleWidth - 32)

        let spaceAbove = anchor.minY - insets.top
        let spaceBelow = size.height - insets.bottom - anchor.maxY
        let placeAbove = step.placement == .above || spaceAbove > spaceBelow
        // 没有箭头时把箭头那截高度补进间距，气泡和高亮处的距离保持一致
        let gap: CGFloat = 6 + (showsArrow ? 0 : BubbleShape.arrowSize.height)

        return VStack(spacing: 0) {
            if placeAbove {
                Spacer(minLength: insets.top + 8)
                bubble(arrow: showsArrow ? BubbleArrow(edge: .bottom, x: arrowX) : nil)
                    .frame(width: bubbleWidth)
                Color.clear.frame(height: max(size.height - anchor.minY + gap, 0))
            } else {
                Color.clear.frame(height: max(anchor.maxY + gap, 0))
                bubble(arrow: showsArrow ? BubbleArrow(edge: .top, x: arrowX) : nil)
                    .frame(width: bubbleWidth)
                Spacer(minLength: insets.bottom + 8)
            }
        }
        // 气泡实在放不下时（超大字号），宁可盖住一点高亮处，也别让它出屏：
        // 放上面的保住顶部不钻进状态栏，放下面的保住底部的按钮还点得到
        .frame(width: size.width, height: size.height, alignment: placeAbove ? .top : .bottom)
    }

    // MARK: 居中卡片

    private func cardLayer(insets: EdgeInsets) -> some View {
        ZStack {
            // 开始/结束页不挖洞，蒙层把触摸全拦下
            Rectangle()
                .fill(.black.opacity(0.55))
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)

            // 欢迎卡片在 SE 这种小屏上已经差不多占满一屏，字号再调大就放不下了：放不下时改成可滚动
            ViewThatFits(in: .vertical) {
                tourCard
                ScrollView(showsIndicators: false) {
                    tourCard
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, insets.top + 12)
            .padding(.bottom, insets.bottom + 12)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    private var tourCard: some View {
        TourCard(
            step: step,
            completedChapters: tour.hasCards ? [.addCard] : [],
            onPrimary: tour.advance,
            onDismiss: tour.end
        )
    }
}

extension Color {
    /// 气泡和卡片的底色：浅色下是白；深色下比分组背景再亮一档 ——
    /// 深色界面压暗后几乎还是黑的，#1C1C1E 的气泡叠在上面不够显眼
    fileprivate static let tourSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .tertiarySystemGroupedBackground : .secondarySystemGroupedBackground
    })
}

// MARK: - 蒙层

private struct SpotlightDimming: View {
    let holes: [TourHole]
    let size: CGSize
    let onTapOutside: () -> Void

    var body: some View {
        ZStack {
            // 洞用 destinationOut 从蒙层里"擦掉"：洞是普通视图，换步骤时
            // frame/position 自带动画，高亮会从上一个控件滑到下一个，而不是闪一下
            ZStack {
                Rectangle().fill(.black.opacity(0.55))
                ForEach(holes.indices, id: \.self) { index in
                    let hole = holes[index]
                    RoundedRectangle(cornerRadius: hole.cornerRadius, style: .continuous)
                        .frame(width: hole.rect.width, height: hole.rect.height)
                        .position(x: hole.rect.midX, y: hole.rect.midY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .allowsHitTesting(false)

            ForEach(holes.indices, id: \.self) { index in
                PulseRing(hole: holes[index])
            }
            .allowsHitTesting(false)

            // 只有洞以外的地方接收触摸 —— 洞里的点击原样落到底下的真实控件上
            Color.clear
                .contentShape(dimmedArea)
                .onTapGesture(perform: onTapOutside)
        }
        .accessibilityHidden(true)
    }

    private var dimmedArea: Path {
        let holesPath = holes.reduce(Path()) { $0.union($1.path) }
        return Path(CGRect(origin: .zero, size: size)).subtracting(holesPath)
    }
}

/// 洞边上的描边：一圈常驻的细边，加一圈往外扩散的光环
private struct PulseRing: View {
    let hole: TourHole

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: hole.cornerRadius, style: .continuous)
        ZStack {
            // 深色界面压暗后几乎还是黑的，看不出哪里亮着 —— 全靠这圈常驻的边把高亮处框出来
            shape.stroke(.white.opacity(0.6), lineWidth: 1.5)
            shape.stroke(.white, lineWidth: 2)
                .scaleEffect(expanded ? 1.12 : 1)
                .opacity(reduceMotion || expanded ? 0 : 0.85)
        }
        .frame(width: hole.rect.width, height: hole.rect.height)
        .position(x: hole.rect.midX, y: hole.rect.midY)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                expanded = true
            }
        }
    }
}

// MARK: - 气泡

private struct BubbleArrow: Equatable {
    enum Edge { case top, bottom }
    let edge: Edge
    /// 箭头尖在气泡里的横坐标
    let x: CGFloat
}

private struct TourBubble: View {
    let step: TourStep
    let canSkip: Bool
    var arrow: BubbleArrow?
    let onPrimary: () -> Void
    let onSkip: () -> Void
    let onClose: () -> Void

    @AccessibilityFocusState private var titleFocused: Bool

    private var accent: Color { step.chapter?.color ?? .blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Text(step.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)

            Text(step.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let footnote = step.footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
                .padding(.top, 2)
        }
        .padding(16)
        .padding(arrow?.edge == .top ? .top : .bottom, arrow == nil ? 0 : BubbleShape.arrowSize.height)
        .background {
            BubbleShape(arrow: arrow)
                .fill(Color.tourSurface)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
        .task(id: step) {
            // 等气泡动画落定再把 VoiceOver 焦点移过来，否则会读到上一步的内容
            try? await Task.sleep(for: .milliseconds(400))
            titleFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: step.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(accent.gradient))
                .accessibilityHidden(true)

            if let chapter = step.chapter {
                Text(chapter.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                    // 视觉上小，点按区域按 44pt 给
                    .padding(9)
                    .contentShape(Rectangle())
                    .padding(-9)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("退出导览"))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let chapter = step.chapter {
                ChapterProgress(current: chapter)
            }

            Spacer(minLength: 8)

            if canSkip {
                Button("跳过", action: onSkip)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }

            if let primaryTitle = step.primaryTitle {
                Button(action: onPrimary) {
                    Text(primaryTitle)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(accent)
            } else if step.style == .spotlight {
                // 没有「下一步」是故意的：这一步要用户自己点真实的按钮
                Label("点高亮处继续", systemImage: "hand.tap.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accent)
            }
        }
    }
}

/// 四章的进度点
private struct ChapterProgress: View {
    let current: TourChapter

    var body: some View {
        HStack(spacing: 5) {
            ForEach(TourChapter.allCases, id: \.self) { chapter in
                Capsule()
                    .fill(fill(for: chapter))
                    .frame(width: chapter == current ? 16 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("第 \(current.rawValue + 1) 部分，共 \(TourChapter.allCases.count) 部分"))
    }

    private func fill(for chapter: TourChapter) -> Color {
        if chapter == current { return current.color }
        if chapter.rawValue < current.rawValue { return current.color.opacity(0.35) }
        return Color.secondary.opacity(0.25)
    }
}

/// 圆角矩形 + 指向高亮处的小三角
private struct BubbleShape: Shape {
    var arrow: BubbleArrow?

    static let arrowSize = CGSize(width: 18, height: 9)
    private let cornerRadius: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        guard let arrow else {
            return Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        }

        let size = Self.arrowSize
        var body = rect
        body.size.height -= size.height
        if arrow.edge == .top { body.origin.y += size.height }

        // 箭头不能伸进圆角里
        let x = min(max(arrow.x, cornerRadius + size.width / 2), rect.width - cornerRadius - size.width / 2)
        var triangle = Path()
        switch arrow.edge {
        case .top:
            triangle.move(to: CGPoint(x: x - size.width / 2, y: body.minY + 1))
            triangle.addLine(to: CGPoint(x: x, y: rect.minY))
            triangle.addLine(to: CGPoint(x: x + size.width / 2, y: body.minY + 1))
        case .bottom:
            triangle.move(to: CGPoint(x: x - size.width / 2, y: body.maxY - 1))
            triangle.addLine(to: CGPoint(x: x, y: rect.maxY))
            triangle.addLine(to: CGPoint(x: x + size.width / 2, y: body.maxY - 1))
        }
        triangle.closeSubpath()

        return Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous).union(triangle)
    }
}

// MARK: - 开始 / 结束卡片

private struct TourCard: View {
    let step: TourStep
    /// 欢迎卡片上打勾、导览会直接跳过的章节（目前只有「已经有卡」时的添加卡片）
    var completedChapters: Set<TourChapter> = []
    let onPrimary: () -> Void
    let onDismiss: () -> Void

    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            icon

            VStack(spacing: 8) {
                Text(step.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)

                Text(step.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step == .welcome {
                chapterList
            }

            if let footnote = step.footnote {
                Label {
                    Text(footnote)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                if let primaryTitle = step.primaryTitle {
                    Button(action: onPrimary) {
                        Text(primaryTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }

                if step == .welcome {
                    Button("跳过，我自己逛逛", action: onDismiss)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.tourSurface)
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        )
        .task(id: step) {
            try? await Task.sleep(for: .milliseconds(400))
            titleFocused = true
        }
    }

    @ViewBuilder
    private var icon: some View {
        if step == .finish {
            Image(systemName: step.systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(Circle().fill(Color.green.gradient))
                .symbolEffect(.bounce, options: .nonRepeating, value: step)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.30, green: 0.55, blue: 1.0),
                                     Color(red: 0.50, green: 0.35, blue: 0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                )
                .accessibilityHidden(true)
        }
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(TourChapter.allCases, id: \.self) { chapter in
                let isDone = completedChapters.contains(chapter)
                HStack(spacing: 12) {
                    Image(systemName: chapter.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(chapter.color.gradient)
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.title)
                            .font(.subheadline.weight(.semibold))
                        Text(chapter.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if isDone {
                        Spacer(minLength: 8)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                            .accessibilityLabel(Text("已完成"))
                    }
                }
                .opacity(isDone ? 0.6 : 1)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("导览 · 首启（叠在真实界面上）") {
    // 欢迎卡片 → 开始导览后会切到卡包页高亮 ⋯；一路点下去能走完整个流程
    ContentView()
        .previewEnvironment(onboardingSeen: false)
}

#Preview("欢迎卡片") {
    ZStack {
        Color.black.opacity(0.55).ignoresSafeArea()
        TourCard(step: .welcome, onPrimary: {}, onDismiss: {})
            .padding(.horizontal, 24)
    }
}

#Preview("欢迎卡片 · 已经有卡") {
    // 换机/重装后卡片从 iCloud 同步回来：添加卡片那章打勾，开始导览后直接跳到拍小票
    ZStack {
        Color.black.opacity(0.55).ignoresSafeArea()
        TourCard(step: .welcome, completedChapters: [.addCard], onPrimary: {}, onDismiss: {})
            .padding(.horizontal, 24)
    }
}

#Preview("结束卡片") {
    ZStack {
        Color.black.opacity(0.55).ignoresSafeArea()
        TourCard(step: .finish, onPrimary: {}, onDismiss: {})
            .padding(.horizontal, 24)
    }
}

#Preview("气泡 · 各种样式", traits: .sizeThatFitsLayout) {
    // 上：要用户自己点（无主按钮，有跳过）；中：讲解步骤；下：长文案 + 脚注
    VStack(spacing: 24) {
        TourBubble(step: .openTemplates, canSkip: true,
                   arrow: BubbleArrow(edge: .top, x: 300),
                   onPrimary: {}, onSkip: {}, onClose: {})
        TourBubble(step: .cameraShutter, canSkip: true,
                   arrow: BubbleArrow(edge: .bottom, x: 170),
                   onPrimary: {}, onSkip: {}, onClose: {})
        TourBubble(step: .screenshotShortcut, canSkip: false,
                   arrow: nil,
                   onPrimary: {}, onSkip: {}, onClose: {})
    }
    .frame(width: 370)
    .padding()
    .background(Color.black.opacity(0.55))
}

#Preview("挖空 · 两个洞", traits: .fixedLayout(width: 390, height: 300)) {
    // 拍一笔页「相册 + 手动」那一步：一次挖两个洞，洞里的点击能落到底下
    ZStack {
        LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom)
        SpotlightDimming(
            holes: [TourHole(rect: CGRect(x: 30, y: 200, width: 76, height: 76), cornerRadius: 38),
                    TourHole(rect: CGRect(x: 284, y: 200, width: 76, height: 76), cornerRadius: 38)],
            size: CGSize(width: 390, height: 300),
            onTapOutside: {}
        )
    }
}
#endif
