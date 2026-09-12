import SwiftUI

// MARK: - 主入口

struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var phase: OnboardingPhase = .splash

    var body: some View {
        ZStack {
            // 贯穿全流程的深色渐变背景
            backgroundGradient
                .ignoresSafeArea()

            // 浮动粒子（features 和 getStarted 阶段显示）
            if phase != .splash {
                FloatingParticlesView()
                    .ignoresSafeArea()
                    .transition(.opacity.animation(.easeIn(duration: 0.8)))
            }

            // 阶段内容
            switch phase {
            case .splash:
                SplashPhaseView {
                    withAnimation(.spring(duration: 0.7, bounce: 0.3)) {
                        phase = .features
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))

            case .features:
                FeatureShowcaseView {
                    withAnimation(.spring(duration: 0.6, bounce: 0.25)) {
                        phase = .getStarted
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

            case .getStarted:
                GetStartedPhaseView(onFinish: onFinish)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
    }

    private var backgroundGradient: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
            ],
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.04, green: 0.04, blue: 0.12),
                    Color(red: 0.06, green: 0.05, blue: 0.16),
                    Color(red: 0.04, green: 0.04, blue: 0.14),
                    Color(red: 0.05, green: 0.06, blue: 0.14),
                    Color(red: 0.08, green: 0.06, blue: 0.18),
                    Color(red: 0.05, green: 0.07, blue: 0.15),
                    Color(red: 0.04, green: 0.05, blue: 0.10),
                    Color(red: 0.06, green: 0.04, blue: 0.13),
                    Color(red: 0.04, green: 0.04, blue: 0.11)
                ]
                : [
                    Color(red: 0.93, green: 0.95, blue: 1.00),
                    Color(red: 0.90, green: 0.93, blue: 1.00),
                    Color(red: 0.94, green: 0.96, blue: 1.00),
                    Color(red: 0.91, green: 0.95, blue: 0.99),
                    Color(red: 0.88, green: 0.92, blue: 1.00),
                    Color(red: 0.92, green: 0.94, blue: 1.00),
                    Color(red: 0.94, green: 0.96, blue: 0.99),
                    Color(red: 0.91, green: 0.94, blue: 1.00),
                    Color(red: 0.93, green: 0.95, blue: 1.00)
                ]
        )
    }
}

// MARK: - 阶段枚举

private enum OnboardingPhase {
    case splash, features, getStarted
}

// MARK: - ① Splash 开屏阶段

private struct SplashPhaseView: View {
    let onAdvance: () -> Void

    @State private var logoScale: CGFloat = 0.3
    @State private var logoOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var subtitleOpacity: Double = 0
    @State private var shimmerActive = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Logo + 闪光效果
            ZStack {
                // 外圈发光
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.blue.opacity(0.25),
                                Color.blue.opacity(0.08),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 40,
                            endRadius: 120
                        )
                    )
                    .frame(width: 240, height: 240)
                    .scaleEffect(logoScale)

                // 主图标容器
                ZStack {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 130, height: 130)
                        .shadow(color: .blue.opacity(0.3), radius: 30, y: 10)

                    Image(systemName: "creditcard")
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.30, green: 0.55, blue: 1.0),
                                    Color(red: 0.50, green: 0.35, blue: 0.95)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shimmer(active: shimmerActive, duration: 1.5)
            }
            .scaleEffect(logoScale)
            .opacity(logoOpacity)

            // 品牌文字
            VStack(spacing: 10) {
                Text("Cashback Counter")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.primary, .primary.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(titleOpacity)

                Text("你的智能返现计算助手")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                    .opacity(subtitleOpacity)
            }

            Spacer()
            Spacer()
        }
        .onAppear {
            // 序列动画
            withAnimation(.spring(duration: 0.8, bounce: 0.4)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.4)) {
                titleOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.6)) {
                subtitleOpacity = 1.0
            }
            // 闪光效果在 logo 动画完成后启动
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                shimmerActive = true
            }
            // 自动跳转
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                onAdvance()
            }
        }
    }
}

// MARK: - ② 功能展示阶段

private struct FeatureShowcaseView: View {
    let onAdvance: () -> Void

    @State private var currentPage = 0
    @State private var cardAppeared = false

    private let features: [FeatureItem] = [
        FeatureItem(
            icon: "camera.viewfinder",
            title: "智能记账",
            subtitle: "拍照识别 · 截屏识别",
            description: "拍照或使用快捷指令截图，快速记录消费。或上传结单 PDF 自动对账。",
            gradient: [
                Color(red: 0.20, green: 0.50, blue: 1.0),
                Color(red: 0.35, green: 0.65, blue: 1.0)
            ],
            animationType: .receiptScan
        ),
        FeatureItem(
            icon: "chart.line.uptrend.xyaxis",
            title: "趋势洞察",
            subtitle: "支出分析 · 积分进度",
            description: "查看支出趋势与积分进度，让每一笔消费更有方向。",
            gradient: [
                Color(red: 0.45, green: 0.30, blue: 0.95),
                Color(red: 0.60, green: 0.45, blue: 1.0)
            ],
            animationType: .trendChart
        ),
        FeatureItem(
            icon: "creditcard.fill",
            title: "卡包管理",
            subtitle: "规则配置 · 返现追踪",
            description: "从模版卡中添加信用卡，自动配置返现/积分规则，随时查看卡片详情与收益。",
            gradient: [
                Color(red: 0.10, green: 0.70, blue: 0.55),
                Color(red: 0.20, green: 0.80, blue: 0.65)
            ],
            animationType: .cardWallet
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 跳过按钮
            HStack {
                Spacer()
                Button("跳过") {
                    onAdvance()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }

            Spacer()

            // 功能卡片
            TabView(selection: $currentPage) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    FeatureCardView(feature: feature)
                        .tag(index)
                        .padding(.horizontal, 28)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 440)

            Spacer()
                .frame(height: 32)

            // 自定义页面指示器
            HStack(spacing: 10) {
                ForEach(0..<features.count, id: \.self) { index in
                    Capsule()
                        .fill(index == currentPage
                              ? AnyShapeStyle(features[currentPage].gradient.first!.gradient)
                              : AnyShapeStyle(Color.secondary.opacity(0.3)))
                        .frame(width: index == currentPage ? 28 : 8, height: 8)
                        .animation(.spring(duration: 0.4), value: currentPage)
                }
            }

            Spacer()
                .frame(height: 32)

            // 下一步 / 继续按钮
            Button(action: advancePage) {
                HStack(spacing: 8) {
                    Text(currentPage == features.count - 1 ? "继续" : "下一步")
                        .font(.headline)
                    if currentPage == features.count - 1 {
                        Image(systemName: "arrow.right")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: features[currentPage].gradient,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: features[currentPage].gradient.first!.opacity(0.4), radius: 12, y: 6)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 48)
            .animation(.easeInOut(duration: 0.3), value: currentPage)
        }
    }

    private func advancePage() {
        if currentPage < features.count - 1 {
            withAnimation(.spring(duration: 0.5, bounce: 0.2)) {
                currentPage += 1
            }
        } else {
            onAdvance()
        }
    }
}

// MARK: - 功能卡片

private struct FeatureCardView: View {
    let feature: FeatureItem

    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 28) {
            // 图标区 — 根据 animationType 显示不同内容
            Group {
                switch feature.animationType {
                case .receiptScan:
                    ReceiptScanAnimationView(
                        gradient: feature.gradient,
                        appeared: appeared
                    )
                    .frame(height: 160)
                case .trendChart:
                    TrendChartAnimationView(
                        gradient: feature.gradient,
                        appeared: appeared
                    )
                    .frame(height: 160)
                case .cardWallet:
                    CardWalletAnimationView(
                        gradient: feature.gradient,
                        appeared: appeared
                    )
                    .frame(height: 160)
                case .none:
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        feature.gradient.first!.opacity(0.3),
                                        feature.gradient.first!.opacity(0.05),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 20,
                                    endRadius: 80
                                )
                            )
                            .frame(width: 160, height: 160)

                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: feature.gradient,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 90, height: 90)
                            .shadow(color: feature.gradient.first!.opacity(0.4), radius: 16, y: 8)

                        Image(systemName: feature.icon)
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }
            }
            .scaleEffect(appeared ? 1.0 : 0.6)
            .opacity(appeared ? 1.0 : 0)

            // 文字区
            VStack(spacing: 12) {
                Text(feature.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text(feature.subtitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: feature.gradient,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Text(feature.description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 8)
            }
            .offset(y: appeared ? 0 : 20)
            .opacity(appeared ? 1.0 : 0)
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 20, y: 10)
        )
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.3)) {
                appeared = true
            }
        }
        .onDisappear {
            appeared = false
        }
    }
}

// MARK: - ③ 开始使用阶段

private struct GetStartedPhaseView: View {
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 主内容
            VStack(spacing: 24) {
                // 大图标
                ZStack {
                    // 脉冲光环
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.30, green: 0.55, blue: 1.0).opacity(0.5),
                                    Color(red: 0.50, green: 0.35, blue: 0.95).opacity(0.2)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 130, height: 130)
                        .scaleEffect(pulseScale)
                        .opacity(Double(2.0 - pulseScale))

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.30, green: 0.55, blue: 1.0),
                                    Color(red: 0.50, green: 0.35, blue: 0.95)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 100)
                        .shadow(color: Color(red: 0.40, green: 0.45, blue: 1.0).opacity(0.4), radius: 20, y: 8)

                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .scaleEffect(appeared ? 1.0 : 0.5)
                .opacity(appeared ? 1.0 : 0)

                VStack(spacing: 10) {
                    Text("一切就绪")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)

                    Text("开始管理你的消费与返现吧")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .offset(y: appeared ? 0 : 16)
                .opacity(appeared ? 1.0 : 0)
            }

            Spacer()

            // 更新须知（保留原有信息）
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("建议在更新版本前，提前在设置页将全部数据导出并保存")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
            .opacity(appeared ? 0.8 : 0)

            // CTA 按钮
            Button(action: onFinish) {
                Text("开始使用")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.30, green: 0.55, blue: 1.0),
                                Color(red: 0.50, green: 0.35, blue: 0.95)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Color(red: 0.40, green: 0.45, blue: 1.0).opacity(0.5), radius: 16, y: 8)
            }
            .shimmer(active: appeared, duration: 2.5)
            .padding(.horizontal, 28)
            .padding(.bottom, 48)
            .scaleEffect(appeared ? 1.0 : 0.9)
            .opacity(appeared ? 1.0 : 0)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.8, bounce: 0.35).delay(0.1)) {
                appeared = true
            }
            // 脉冲动画
            withAnimation(
                .easeInOut(duration: 1.8)
                .repeatForever(autoreverses: false)
            ) {
                pulseScale = 1.6
            }
        }
    }
}

// MARK: - 数据模型

private enum FeatureAnimationType {
    case none
    case receiptScan
    case trendChart
    case cardWallet
}

private struct FeatureItem {
    let icon: String
    let title: String
    let subtitle: String
    let description: String
    let gradient: [Color]
    var animationType: FeatureAnimationType = .none
}

// MARK: - 📱 收据扫描动画

/// 模拟截屏识别记账的动画效果：
/// 1. 收据卡片滑入
/// 2. 蓝色扫描线从上到下扫过
/// 3. 字段依次高亮并打勾（金额 → 商户 → 日期）
private struct ReceiptScanAnimationView: View {
    let gradient: [Color]
    let appeared: Bool

    @State private var receiptOffset: CGFloat = 30
    @State private var receiptOpacity: Double = 0
    @State private var scanLineY: CGFloat = -1.0  // -1 = top, 1 = bottom (normalized)
    @State private var scanLineOpacity: Double = 0
    @State private var field1Highlight = false
    @State private var field2Highlight = false
    @State private var field3Highlight = false
    @State private var scanComplete = false

    private let receiptHeight: CGFloat = 150
    private let receiptWidth: CGFloat = 200

    var body: some View {
        ZStack {
            // 外圈光晕
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            gradient.first!.opacity(0.2),
                            gradient.first!.opacity(0.03),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 30,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)

            // 收据卡片
            ZStack(alignment: .top) {
                // 收据背景
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.systemBackground).opacity(0.95))
                    .shadow(color: gradient.first!.opacity(0.2), radius: 12, y: 4)

                // 收据内容
                VStack(alignment: .leading, spacing: 0) {
                    // 标题栏
                    HStack {
                        Circle()
                            .fill(gradient.first!.opacity(0.15))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(gradient.first!)
                            )
                        Text("交易识别")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.primary.opacity(0.8))
                        Spacer()
                        if scanComplete {
                            Text("已识别")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                    Divider().padding(.horizontal, 8)

                    // 字段行
                    VStack(spacing: 6) {
                        receiptRow(
                            label: "金额",
                            value: "¥10.00",
                            highlighted: field1Highlight,
                            icon: "yensign.circle.fill"
                        )
                        receiptRow(
                            label: "商户",
                            value: "CashbackCounter",
                            highlighted: field2Highlight,
                            icon: "storefront.fill"
                        )
                        receiptRow(
                            label: "日期",
                            value: Date().formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.locale)),
                            highlighted: field3Highlight,
                            icon: "calendar"
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }

                // 扫描线
                if scanLineOpacity > 0 {
                    scanLine
                }
            }
            .frame(width: receiptWidth, height: receiptHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .offset(y: receiptOffset)
            .opacity(receiptOpacity)
        }
        .onChange(of: appeared) { _, newValue in
            if newValue {
                startAnimation()
            } else {
                resetAnimation()
            }
        }
        .onAppear {
            if appeared {
                startAnimation()
            }
        }
    }

    // 扫描线视图
    private var scanLine: some View {
        GeometryReader { geo in
            let yPos = (scanLineY + 1) / 2 * geo.size.height  // map [-1,1] → [0, height]
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            gradient.first!.opacity(0.6),
                            gradient.first!,
                            gradient.first!.opacity(0.6),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 2)
                .shadow(color: gradient.first!.opacity(0.8), radius: 6, y: 0)
                .offset(y: yPos)
                .opacity(scanLineOpacity)
        }
    }

    // 收据行
    private func receiptRow(label: String, value: String, highlighted: Bool, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(highlighted ? gradient.first! : .secondary.opacity(0.5))
                .frame(width: 14)

            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)

            Text(value)
                .font(.system(size: 11, weight: highlighted ? .bold : .regular, design: .monospaced))
                .foregroundColor(highlighted ? .primary : .secondary.opacity(0.6))

            Spacer()

            // 识别成功标记
            if highlighted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? gradient.first!.opacity(0.08) : Color.clear)
        )
        .animation(.spring(duration: 0.4), value: highlighted)
    }

    // 动画序列
    private func startAnimation() {
        // 1. 收据卡片滑入
        withAnimation(.spring(duration: 0.6, bounce: 0.3)) {
            receiptOffset = 0
            receiptOpacity = 1
        }

        // 2. 扫描线出现并扫过 (0.6s 后)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            scanLineY = -1.0
            withAnimation(.easeIn(duration: 0.1)) {
                scanLineOpacity = 1
            }
            withAnimation(.easeInOut(duration: 1.2)) {
                scanLineY = 1.0
            }
        }

        // 3. 字段依次高亮
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation { field1Highlight = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { field2Highlight = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { field3Highlight = true }
        }

        // 4. 扫描线消失 + 显示"已识别"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                scanLineOpacity = 0
            }
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) {
                scanComplete = true
            }
        }
    }

    private func resetAnimation() {
        receiptOffset = 30
        receiptOpacity = 0
        scanLineY = -1.0
        scanLineOpacity = 0
        field1Highlight = false
        field2Highlight = false
        field3Highlight = false
        scanComplete = false
    }
}

// MARK: - 📈 趋势图表动画

/// 模拟趋势分析的动画效果：
/// 1. 图表容器淡入
/// 2. 折线图逐段绘制
/// 3. 数据点依次亮起
/// 4. 趋势箭头弹出
private struct TrendChartAnimationView: View {
    let gradient: [Color]
    let appeared: Bool

    @State private var chartOpacity: Double = 0
    @State private var chartOffset: CGFloat = 20
    @State private var lineProgress: CGFloat = 0
    @State private var point1Visible = false
    @State private var point2Visible = false
    @State private var point3Visible = false
    @State private var point4Visible = false
    @State private var point5Visible = false
    @State private var trendArrowVisible = false
    @State private var barHeights: [CGFloat] = [0, 0, 0, 0, 0]

    // 数据点（归一化坐标 0~1）
    private let dataPoints: [(x: CGFloat, y: CGFloat)] = [
        (0.05, 0.70),
        (0.25, 0.45),
        (0.50, 0.60),
        (0.72, 0.30),
        (0.95, 0.15)
    ]
    private let targetBarHeights: [CGFloat] = [0.45, 0.65, 0.50, 0.80, 0.95]

    var body: some View {
        ZStack {
            // 外圈光晕
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            gradient.first!.opacity(0.2),
                            gradient.first!.opacity(0.03),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 30,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)

            // 图表卡片
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.systemBackground).opacity(0.95))
                    .shadow(color: gradient.first!.opacity(0.2), radius: 12, y: 4)

                VStack(alignment: .leading, spacing: 0) {
                    // 标题栏
                    HStack {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(gradient.first!)
                        Text("支出趋势")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.primary.opacity(0.8))
                        Spacer()
                        if trendArrowVisible {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                                Text("+12%")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    // 图表区域
                    GeometryReader { geo in
                        let w = geo.size.width - 24
                        let h = geo.size.height - 8

                        ZStack(alignment: .bottom) {
                            // 柱状图背景
                            HStack(alignment: .bottom, spacing: 6) {
                                ForEach(0..<5, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(gradient.first!.opacity(0.1))
                                        .frame(height: barHeights[i] * h * 0.85)
                                }
                            }
                            .padding(.horizontal, 16)

                            // 折线
                            Path { path in
                                let points = dataPoints.map { pt in
                                    CGPoint(
                                        x: 12 + pt.x * w,
                                        y: 4 + pt.y * h
                                    )
                                }
                                guard !points.isEmpty else { return }
                                path.move(to: points[0])
                                for i in 1..<points.count {
                                    let prev = points[i - 1]
                                    let curr = points[i]
                                    let control1 = CGPoint(x: (prev.x + curr.x) / 2, y: prev.y)
                                    let control2 = CGPoint(x: (prev.x + curr.x) / 2, y: curr.y)
                                    path.addCurve(to: curr, control1: control1, control2: control2)
                                }
                            }
                            .trim(from: 0, to: lineProgress)
                            .stroke(
                                LinearGradient(
                                    colors: gradient,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                            )

                            // 数据点
                            ForEach(Array(dataPoints.enumerated()), id: \.offset) { i, pt in
                                let visible = [point1Visible, point2Visible, point3Visible, point4Visible, point5Visible][i]
                                Circle()
                                    .fill(gradient.first!)
                                    .frame(width: 7, height: 7)
                                    .shadow(color: gradient.first!.opacity(0.5), radius: 3)
                                    .scaleEffect(visible ? 1.0 : 0)
                                    .opacity(visible ? 1.0 : 0)
                                    .position(
                                        x: 12 + pt.x * w,
                                        y: 4 + pt.y * h
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
            }
            .frame(width: 200, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .offset(y: chartOffset)
            .opacity(chartOpacity)
        }
        .onChange(of: appeared) { _, newValue in
            if newValue { startAnimation() } else { resetAnimation() }
        }
        .onAppear {
            if appeared { startAnimation() }
        }
    }

    private func startAnimation() {
        // 1. 卡片入场
        withAnimation(.spring(duration: 0.6, bounce: 0.3)) {
            chartOffset = 0
            chartOpacity = 1
        }

        // 2. 柱状图升起
        for i in 0..<5 {
            withAnimation(.spring(duration: 0.5, bounce: 0.2).delay(0.3 + Double(i) * 0.08)) {
                barHeights[i] = targetBarHeights[i]
            }
        }

        // 3. 折线绘制
        withAnimation(.easeInOut(duration: 1.2).delay(0.5)) {
            lineProgress = 1.0
        }

        // 4. 数据点依次出现
        let pointDelays = [0.6, 0.9, 1.1, 1.3, 1.5]
        for (i, delay) in pointDelays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.spring(duration: 0.35, bounce: 0.4)) {
                    switch i {
                    case 0: point1Visible = true
                    case 1: point2Visible = true
                    case 2: point3Visible = true
                    case 3: point4Visible = true
                    case 4: point5Visible = true
                    default: break
                    }
                }
            }
        }

        // 5. 趋势箭头
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) {
                trendArrowVisible = true
            }
        }
    }

    private func resetAnimation() {
        chartOpacity = 0
        chartOffset = 20
        lineProgress = 0
        point1Visible = false
        point2Visible = false
        point3Visible = false
        point4Visible = false
        point5Visible = false
        trendArrowVisible = false
        barHeights = [0, 0, 0, 0, 0]
    }
}

// MARK: - 💳 卡包动画

/// 模拟卡包管理的动画效果：
/// 1. 信用卡依次从底部扇形展开
/// 2. 每张卡出现后显示返现比例标签
/// 3. 最后显示"已配置"状态
private struct CardWalletAnimationView: View {
    let gradient: [Color]
    let appeared: Bool

    @State private var card1Visible = false
    @State private var card2Visible = false
    @State private var card3Visible = false
    @State private var badge1Visible = false
    @State private var badge2Visible = false
    @State private var badge3Visible = false
    @State private var configComplete = false

    private let cardColors: [[Color]] = [
        [Color(red: 0.15, green: 0.15, blue: 0.20), Color(red: 0.25, green: 0.25, blue: 0.35)],
        [Color(red: 0.10, green: 0.45, blue: 0.85), Color(red: 0.20, green: 0.55, blue: 0.95)],
        [Color(red: 0.85, green: 0.55, blue: 0.10), Color(red: 0.95, green: 0.65, blue: 0.20)]
    ]
    private let cardLabels = ["**** 8091", "**** 4532", "**** 7766"]
    private let bankNames = ["Chase", "BOA", "AMEX"]
    private let cashbackRates = ["5%", "3%", "2%"]

    var body: some View {
        ZStack {
            // 外圈光晕
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            gradient.first!.opacity(0.2),
                            gradient.first!.opacity(0.03),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 30,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)

            // 卡片堆叠
            ZStack {
                // 第 3 张卡 (底)
                miniCard(index: 2)
                    .rotationEffect(.degrees(card3Visible ? 8 : 0), anchor: .bottom)
                    .offset(y: card3Visible ? -8 : 20)
                    .opacity(card3Visible ? 1 : 0)
                    .scaleEffect(card3Visible ? 0.92 : 0.7)

                // 第 2 张卡 (中)
                miniCard(index: 1)
                    .rotationEffect(.degrees(card2Visible ? -5 : 0), anchor: .bottom)
                    .offset(y: card2Visible ? -4 : 20)
                    .opacity(card2Visible ? 1 : 0)
                    .scaleEffect(card2Visible ? 0.96 : 0.7)

                // 第 1 张卡 (顶)
                miniCard(index: 0)
                    .offset(y: card1Visible ? 0 : 20)
                    .opacity(card1Visible ? 1 : 0)
                    .scaleEffect(card1Visible ? 1.0 : 0.7)
            }

            // 返现标签
            if badge1Visible {
                cashbackBadge(rate: cashbackRates[0], color: .green)
                    .offset(x: 85, y: -50)
                    .transition(.scale.combined(with: .opacity))
            }
            if badge2Visible {
                cashbackBadge(rate: cashbackRates[1], color: Color(red: 0.20, green: 0.55, blue: 0.95))
                    .offset(x: -85, y: -20)
                    .transition(.scale.combined(with: .opacity))
            }
            if badge3Visible {
                cashbackBadge(rate: cashbackRates[2], color: .orange)
                    .offset(x: 80, y: 15)
                    .transition(.scale.combined(with: .opacity))
            }

            // 已配置标签
            if configComplete {
                VStack(spacing: 2) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14))
                    Text("已配置")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                }
                .foregroundColor(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.green.opacity(0.12))
                )
                .offset(x: 0, y: 68)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onChange(of: appeared) { _, newValue in
            if newValue { startAnimation() } else { resetAnimation() }
        }
        .onAppear {
            if appeared { startAnimation() }
        }
    }

    private func miniCard(index: Int) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: cardColors[index],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // 装饰圆
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 60, height: 60)
                .offset(x: 110, y: -15)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(bankNames[index])
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                Text(cardLabels[index])
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(10)
        }
        .frame(width: 160, height: 90)
    }

    private func cashbackBadge(rate: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "percent")
                .font(.system(size: 7, weight: .bold))
            Text(rate)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundColor(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
                .overlay(
                    Capsule()
                        .stroke(color.opacity(0.3), lineWidth: 0.5)
                )
        )
    }

    private func startAnimation() {
        // 1. 卡片依次扇形展开
        withAnimation(.spring(duration: 0.5, bounce: 0.3)) {
            card1Visible = true
        }
        withAnimation(.spring(duration: 0.5, bounce: 0.3).delay(0.2)) {
            card2Visible = true
        }
        withAnimation(.spring(duration: 0.5, bounce: 0.3).delay(0.4)) {
            card3Visible = true
        }

        // 2. 返现标签依次弹出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.spring(duration: 0.4, bounce: 0.35)) {
                badge1Visible = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.spring(duration: 0.4, bounce: 0.35)) {
                badge2Visible = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.spring(duration: 0.4, bounce: 0.35)) {
                badge3Visible = true
            }
        }

        // 3. 已配置标签
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) {
                configComplete = true
            }
        }
    }

    private func resetAnimation() {
        card1Visible = false
        card2Visible = false
        card3Visible = false
        badge1Visible = false
        badge2Visible = false
        badge3Visible = false
        configComplete = false
    }
}

// MARK: - ✨ Shimmer 闪光效果修饰符

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    let duration: Double

    @State private var offset: CGFloat = -1.0

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geo in
                        let width = geo.size.width
                        let height = geo.size.height
                        let diagonal = sqrt(width * width + height * height)

                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .white.opacity(0.15), location: 0.35),
                                .init(color: .white.opacity(0.35), location: 0.5),
                                .init(color: .white.opacity(0.15), location: 0.65),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: diagonal * 0.6, height: diagonal * 2)
                        .rotationEffect(.degrees(-25))
                        .offset(x: offset * diagonal * 1.2)
                        .frame(width: width, height: height, alignment: .leading)
                        .clipped()
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onChange(of: active) { _, newValue in
                if newValue {
                    startAnimation()
                }
            }
            .onAppear {
                if active {
                    startAnimation()
                }
            }
    }

    private func startAnimation() {
        offset = -1.0
        withAnimation(
            .easeInOut(duration: duration)
            .repeatCount(3, autoreverses: false)
        ) {
            offset = 2.0
        }
    }
}

extension View {
    fileprivate func shimmer(active: Bool, duration: Double = 1.5) -> some View {
        modifier(ShimmerModifier(active: active, duration: duration))
    }
}

// MARK: - 🌟 浮动粒子背景

private struct FloatingParticlesView: View {
    @State private var particles: [Particle] = []
    private let particleCount = 30

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                for particle in particles {
                    let x = particle.baseX * size.width
                        + sin(time * particle.speedX + particle.phaseX) * particle.amplitudeX
                    let y = particle.baseY * size.height
                        + cos(time * particle.speedY + particle.phaseY) * particle.amplitudeY

                    let alpha = 0.15 + 0.2 * sin(time * particle.blinkSpeed + particle.phaseX)
                    let radius = particle.radius

                    let rect = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )

                    context.opacity = alpha
                    context.fill(
                        Circle().path(in: rect),
                        with: .color(particle.color)
                    )
                }
            }
        }
        .onAppear {
            particles = (0..<particleCount).map { _ in
                Particle(
                    baseX: CGFloat.random(in: 0...1),
                    baseY: CGFloat.random(in: 0...1),
                    radius: CGFloat.random(in: 1.5...4),
                    speedX: Double.random(in: 0.2...0.6),
                    speedY: Double.random(in: 0.15...0.5),
                    amplitudeX: CGFloat.random(in: 15...40),
                    amplitudeY: CGFloat.random(in: 15...35),
                    phaseX: Double.random(in: 0...(.pi * 2)),
                    phaseY: Double.random(in: 0...(.pi * 2)),
                    blinkSpeed: Double.random(in: 0.5...1.5),
                    color: [
                        Color(red: 0.40, green: 0.60, blue: 1.0),
                        Color(red: 0.55, green: 0.40, blue: 1.0),
                        Color(red: 0.30, green: 0.75, blue: 0.65),
                        Color.white
                    ].randomElement()!
                )
            }
        }
    }
}

private struct Particle {
    let baseX: CGFloat
    let baseY: CGFloat
    let radius: CGFloat
    let speedX: Double
    let speedY: Double
    let amplitudeX: CGFloat
    let amplitudeY: CGFloat
    let phaseX: Double
    let phaseY: Double
    let blinkSpeed: Double
    let color: Color
}

