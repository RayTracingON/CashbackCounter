//
//  OnboardingTour.swift
//  CashbackCounter
//
//  新手导览的状态机：现在走到哪一步、这一步在哪层界面上高亮哪个控件、什么事发生了才往下走。
//
//  导览是叠在**真实界面**上的蒙层，不另画一套示意图 —— 用户在导览里点的，
//  就是以后天天要点的那个按钮。所以这里不碰任何业务逻辑，只做两件事：
//  1. 记下各个可高亮控件当前在屏幕上的位置（由 `.tourTarget(_:)` 上报）；
//  2. 按真实界面上发生的事（打开了模板列表、保存了卡片……）推进步骤。
//
//  画蒙层的视图在 OnboardingView.swift。
//

import SwiftUI

/// 底部五个标签页。导览要替用户切页，用名字比裸写 0…4 不容易对错位。
enum AppTab: Int {
    case bills = 0, cards, camera, points, settings
}

/// 导览里可以被高亮的真实控件。
enum TourTarget: Hashable {
    /// 卡包页右上角 ⋯（未选中卡片时的那个菜单）
    case addCardMenu
    /// 添加卡片页的「尾号」输入框
    case cardLastFour
    /// 添加卡片页的「保存」
    case cardSave
    case cameraShutter
    case cameraLibrary
    case cameraManual
    /// 设置页「获取截屏记账快捷指令」
    case screenshotShortcut
    /// 设置页「自动化配置教程」
    case shortcutGuide
    /// 设置页账号区的「银行同步」
    case bankSync
}

/// 蒙层画在哪一层界面上。
///
/// sheet 是独立的视图层级：根视图上的蒙层盖不进 sheet，sheet 里的控件位置也冒不到根视图。
/// 所以导览会经过的每个 sheet 根部都挂一个宿主，每一步只由它所属的宿主来画。
enum TourHost: Hashable {
    case main
    case templateList
    case addCard
}

/// 导览分四章。气泡上的进度按章算而不是按步算 ——「第 3/11 步」会让人觉得没完没了。
enum TourChapter: Int, CaseIterable {
    case addCard, receipt, screenshot, bankSync

    var title: LocalizedStringKey {
        switch self {
        case .addCard: "添加卡片"
        case .receipt: "拍小票记账"
        case .screenshot: "截屏记账"
        case .bankSync: "银行同步"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .addCard: "用模板一键配好返现规则"
        case .receipt: "AI 自动识别金额、商户和卡片"
        case .screenshot: "操作按钮一键截屏入账"
        case .bankSync: "美国银行交易自动导入"
        }
    }

    var systemImage: String {
        switch self {
        case .addCard: "creditcard.fill"
        case .receipt: "camera.viewfinder"
        case .screenshot: "button.horizontal.top.press.fill"
        case .bankSync: "building.columns.fill"
        }
    }

    var color: Color {
        switch self {
        case .addCard: .blue
        case .receipt: .orange
        case .screenshot: .purple
        case .bankSync: .green
        }
    }
}

/// 导览的每一步。
///
/// 「添加卡片」一章是让用户**真的**加一张：这几步没有「下一步」按钮，
/// 要等真实界面上的事件（`TourEvent`）来推进；其余几章是指给用户看，点「下一步」就走。
enum TourStep: Hashable, CaseIterable {
    case welcome
    /// 高亮卡包页 ⋯，等用户打开模板列表
    case openTemplates
    /// 模板列表里不压暗（整片列表都是可选目标），只浮一张提示卡
    case pickTemplate
    /// 走了「自定义添加」：要填的东西太多，同样只给提示卡
    case fillCustomCard
    case enterLastFour
    case saveCard
    /// 卡已保存、sheet 正在收起：不压暗，让用户看到卡包里多出来的那张卡
    case cardAdded
    case cameraShutter
    case cameraImport
    case screenshotShortcut
    case bankSync
    case finish

    enum Style {
        /// 压暗，只挖空目标控件，气泡指向它；目标控件照常可点
        case spotlight
        /// 不压暗、不拦触摸，底部浮一张提示卡
        case hint
        /// 整屏压暗，居中卡片（开始/结束）
        case card
    }

    /// 气泡放在目标的哪一侧
    enum BubblePlacement {
        case automatic
        /// 目标下方马上会弹键盘时，气泡必须放在上面
        case above
    }

    var chapter: TourChapter? {
        switch self {
        case .welcome, .finish: nil
        case .openTemplates, .pickTemplate, .fillCustomCard, .enterLastFour, .saveCard, .cardAdded: .addCard
        case .cameraShutter, .cameraImport: .receipt
        case .screenshotShortcut: .screenshot
        case .bankSync: .bankSync
        }
    }

    var host: TourHost {
        switch self {
        case .pickTemplate: .templateList
        case .fillCustomCard, .enterLastFour, .saveCard: .addCard
        default: .main
        }
    }

    /// 进入这一步时要切到的标签页；nil = 停在当前页
    var tab: AppTab? {
        switch self {
        case .welcome: nil
        case .openTemplates, .cardAdded: .cards
        case .cameraShutter, .cameraImport: .camera
        case .screenshotShortcut, .bankSync: .settings
        case .finish: .bills
        case .pickTemplate, .fillCustomCard, .enterLastFour, .saveCard: nil
        }
    }

    var style: Style {
        switch self {
        case .welcome, .finish: .card
        case .pickTemplate, .fillCustomCard, .cardAdded: .hint
        default: .spotlight
        }
    }

    var placement: BubblePlacement {
        self == .enterLastFour ? .above : .automatic
    }

    /// 要挖空的控件。多个目标挨在一起时合成一个洞（见 `mergesTargets`）
    var targets: [TourTarget] {
        switch self {
        case .openTemplates: [.addCardMenu]
        case .enterLastFour: [.cardLastFour]
        case .saveCard: [.cardSave]
        case .cameraShutter: [.cameraShutter]
        case .cameraImport: [.cameraLibrary, .cameraManual]
        case .screenshotShortcut: [.screenshotShortcut, .shortcutGuide]
        case .bankSync: [.bankSync]
        default: []
        }
    }

    /// 快捷指令那两行上下相邻，分成两个洞中间会夹一条细细的蒙层，不如合成一个
    var mergesTargets: Bool { self == .screenshotShortcut }

    var systemImage: String {
        switch self {
        case .welcome: "hand.wave.fill"
        case .finish: "checkmark.seal.fill"
        case .enterLastFour: "number"
        case .saveCard: "checkmark.circle.fill"
        case .cardAdded: "party.popper.fill"
        case .cameraImport: "photo.on.rectangle.angled"
        default: chapter?.systemImage ?? "sparkles"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .welcome: "欢迎使用 Cashback Counter"
        case .openTemplates: "添加你的第一张卡"
        case .pickTemplate: "选一张你手上的卡"
        case .fillCustomCard: "自定义一张卡"
        case .enterLastFour: "填上卡号后四位"
        case .saveCard: "保存，就添加好了"
        case .cardAdded: "第一张卡添加好了"
        case .cameraShutter: "拍小票，自动记一笔"
        case .cameraImport: "截图导入或手动记账"
        case .screenshotShortcut: "操作按钮，一键截屏记账"
        case .bankSync: "银行交易自动同步"
        case .finish: "准备就绪"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .welcome:
            "花一分钟，在真实界面里走一遍核心功能。"
        case .openTemplates:
            "点右上角 ⋯，选「从模板添加」。模板已经配好了这张卡的返现和积分规则。"
        case .pickTemplate:
            "右上角可以按银行筛选。找不到你的卡？先取消，再用「自定义添加」手动录入。"
        case .fillCustomCard:
            "填好银行、卡种、尾号和返现规则，然后点右上角「保存」。"
        case .enterLastFour:
            "换成你这张卡的后四位。拍小票时会按尾号自动选中它，银行同步也靠它对上账户。"
        case .saveCard:
            "返现规则已经按模板填好，以后可以在卡包里随时修改。"
        case .cardAdded:
            "点卡片可以查看它的消费记录和返现上限进度，长按可以拖动排序。"
        case .cameraShutter:
            "对准小票按快门，AI 会识别商户、金额、日期和类别，并按尾号自动选好卡片。"
        case .cameraImport:
            "左边从相册选小票或付款截图，右边手动记一笔。"
        case .screenshotShortcut:
            "① 点上面一行，添加截屏记账快捷指令\n② 打开系统设置 › 操作按钮，选「快捷指令」，再选中它\n③ 在付款成功页长按操作按钮，自动截屏入账"
        case .bankSync:
            "绑定美国的信用卡或银行账户后，消费会自动同步进来并算好返现。需要登录并订阅，目前仅支持美国的金融机构。"
        case .finish:
            "想再看一遍，随时到「设置 › 新手导览」。"
        }
    }

    var footnote: LocalizedStringKey? {
        switch self {
        case .screenshotShortcut:
            "没有操作按钮？可以在系统设置 › 辅助功能 › 触控 › 轻点背面 里绑定。"
        case .finish:
            "建议在更新版本前，提前在设置页将全部数据导出并保存"
        default:
            nil
        }
    }

    /// 主按钮。nil = 这一步要用户在真实界面上操作才往下走
    var primaryTitle: LocalizedStringKey? {
        switch self {
        case .welcome: "开始导览"
        case .finish: "开始使用"
        case .openTemplates, .pickTemplate, .fillCustomCard, .saveCard: nil
        // 尾号是选填的，不填也得能往下走
        default: "下一步"
        }
    }
}

/// 真实界面上发生、导览关心的事
enum TourEvent: Equatable {
    case templateListAppeared
    case templateListDisappeared
    /// 只在「新建」时上报，编辑已有卡片不算
    case addCardAppeared(fromTemplate: Bool)
    case addCardDisappeared
    /// 尾号输入框变了；isComplete = 用户刚打满第四位
    case lastFourChanged(isComplete: Bool)
    case cardSaved
}

@Observable
final class OnboardingTour {

    static let shared = OnboardingTour()

    /// 与 ContentView 的 `@AppStorage` 共用这个 key
    static let seenKey = "hasSeenOnboarding"

    /// 当前步骤；nil = 导览没在进行
    private(set) var step: TourStep?

    /// 各可高亮控件在**窗口坐标系**里的位置。
    ///
    /// 一律存，不管导览在不在进行 —— `onGeometryChange` 只在位置变化时回调，
    /// 导览开始时才想起来量就已经晚了。
    private(set) var frames: [TourTarget: CGRect] = [:]

    /// 正在屏幕上的控件。TabView 切走的页面不会销毁，位置还留在 `frames` 里，
    /// 得靠这个判断它此刻是不是真的看得见。
    private(set) var visibleTargets: Set<TourTarget> = []

    /// 每加一，卡包页就收起添加卡片的 sheet（在 sheet 里点了跳过时用）
    private(set) var sheetDismissRequest = 0

    /// 模板列表是否开着 —— 添加页取消后该退回哪一步取决于它
    private var isTemplateListPresented = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isActive: Bool { step != nil }

    /// 目标控件此刻的位置；不在屏幕上时为 nil
    func frame(for target: TourTarget) -> CGRect? {
        visibleTargets.contains(target) ? frames[target] : nil
    }

    // MARK: - 流程

    /// 首次启动自动调一次，设置页「新手导览」也走这里。进行中再调不会从头来。
    func start() {
        guard step == nil else { return }
        move(to: .welcome)
    }

    /// 气泡主按钮
    func advance() {
        guard let step else { return }
        if step == .finish {
            end()
        } else if let next = nextStep(after: step) {
            move(to: next)
        }
    }

    /// 「跳过」去的地方：这一章剩下的步骤都不看了。nil = 这一步不显示「跳过」
    var skipDestination: TourStep? {
        guard let step, let chapter = step.chapter else { return nil }
        let destination: TourStep = switch chapter {
        case .addCard: .cameraShutter
        case .receipt: .screenshotShortcut
        case .screenshot: .bankSync
        case .bankSync: .finish
        }
        // 跳过和下一步去的是同一个地方时，只留「下一步」
        return destination == nextStep(after: step) ? nil : destination
    }

    func skipChapter() {
        guard let destination = skipDestination else { return }
        // 人在 sheet 里时得先把 sheet 收起来，后面几章都在主界面上
        if step?.host != .main {
            sheetDismissRequest += 1
            isTemplateListPresented = false
        }
        move(to: destination)
    }

    /// 欢迎页的「跳过」、气泡右上角的 ✕、结束页的「开始使用」：整个导览结束。
    /// 开着的 sheet 不动 —— 用户可能正填到一半，想自己接着填完。
    func end() {
        defaults.set(true, forKey: Self.seenKey)
        withAnimation(.easeOut(duration: 0.25)) {
            step = nil
        }
    }

    /// 主按钮通往的下一步；nil = 这一步没有主按钮，或者主按钮是「结束」
    private func nextStep(after step: TourStep) -> TourStep? {
        switch step {
        case .welcome: .openTemplates
        case .enterLastFour: .saveCard
        case .cardAdded: .cameraShutter
        case .cameraShutter: .cameraImport
        case .cameraImport: .screenshotShortcut
        case .screenshotShortcut: .bankSync
        case .bankSync: .finish
        case .openTemplates, .pickTemplate, .fillCustomCard, .saveCard, .finish: nil
        }
    }

    // MARK: - 真实界面上报的事件

    func handle(_ event: TourEvent) {
        // 模板列表开没开着要一直记，导览没在进行时也记 ——
        // 「添加页取消后退回哪一步」得知道它底下还垫着什么
        switch event {
        case .templateListAppeared: isTemplateListPresented = true
        case .templateListDisappeared: isTemplateListPresented = false
        default: break
        }

        guard let step else { return }

        switch (event, step) {
        case (.templateListAppeared, .openTemplates):
            move(to: .pickTemplate)

        case (.addCardAppeared(let fromTemplate), .openTemplates),
             (.addCardAppeared(let fromTemplate), .pickTemplate):
            move(to: fromTemplate ? .enterLastFour : .fillCustomCard)

        case (.lastFourChanged(isComplete: true), .enterLastFour):
            move(to: .saveCard)

        case (.cardSaved, .pickTemplate), (.cardSaved, .fillCustomCard),
             (.cardSaved, .enterLastFour), (.cardSaved, .saveCard):
            isTemplateListPresented = false
            move(to: .cardAdded)

        // 用户点了取消：退回上一层界面对应的那一步，而不是卡在一个已经看不见的目标上
        case (.addCardDisappeared, .fillCustomCard),
             (.addCardDisappeared, .enterLastFour),
             (.addCardDisappeared, .saveCard):
            move(to: isTemplateListPresented ? .pickTemplate : .openTemplates)

        case (.templateListDisappeared, .pickTemplate):
            move(to: .openTemplates)

        default:
            break
        }
    }

    // MARK: - 控件位置

    func updateFrame(_ frame: CGRect, for target: TourTarget) {
        frames[target] = frame
    }

    func setVisible(_ visible: Bool, target: TourTarget) {
        if visible {
            visibleTargets.insert(target)
        } else {
            visibleTargets.remove(target)
        }
    }

    // MARK: -

    private func move(to newStep: TourStep) {
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
            step = newStep
        }
    }
}
