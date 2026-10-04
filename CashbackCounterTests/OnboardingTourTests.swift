import XCTest
import CoreGraphics
@testable import CashbackCounter

/// 新手导览的状态机：真实界面上发生的事 → 导览走到哪一步。
///
/// 蒙层画得对不对只能在模拟器里看，但"取消添加后退回哪一步""在 sheet 里跳过要不要收 sheet"
/// 这类分支一旦走错，用户会卡在一个指向已经看不见的控件的蒙层上，只能杀进程。这些在这里钉死。
@MainActor
final class OnboardingTourTests: XCTestCase {

    private var defaults: UserDefaults!
    private var tour: OnboardingTour!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "OnboardingTourTests")
        defaults.removePersistentDomain(forName: "OnboardingTourTests")
        tour = OnboardingTour(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "OnboardingTourTests")
        super.tearDown()
    }

    /// 走到「高亮 ⋯，等用户打开模板列表」
    private func startAddCardChapter() {
        tour.start()
        tour.advance()
        XCTAssertEqual(tour.step, .openTemplates)
    }

    // MARK: - 开始 / 结束

    func testStart_ShowsWelcome_AndRestartingMidwayDoesNothing() {
        XCTAssertFalse(tour.isActive)
        tour.start()
        XCTAssertEqual(tour.step, .welcome)

        tour.advance()
        tour.start() // 设置页再点一次「新手导览」不该把进行中的导览拽回开头
        XCTAssertEqual(tour.step, .openTemplates)
    }

    func testEnd_MarksSeen() {
        tour.start()
        XCTAssertFalse(defaults.bool(forKey: OnboardingTour.seenKey))

        tour.end()

        XCTAssertNil(tour.step)
        XCTAssertTrue(defaults.bool(forKey: OnboardingTour.seenKey))
    }

    func testEventsAreIgnoredWhenTourIsNotRunning() {
        tour.handle(.templateListAppeared)
        tour.handle(.addCardAppeared(fromTemplate: true))
        tour.handle(.cardSaved)
        XCTAssertNil(tour.step)
    }

    // MARK: - 添加卡片：真的走一遍

    func testTemplatePath_WalksThroughTheRealScreens() {
        startAddCardChapter()

        tour.handle(.templateListAppeared)
        XCTAssertEqual(tour.step, .pickTemplate)

        tour.handle(.addCardAppeared(fromTemplate: true))
        XCTAssertEqual(tour.step, .enterLastFour)

        tour.handle(.lastFourChanged(isComplete: false))
        XCTAssertEqual(tour.step, .enterLastFour, "没填满四位不该往下走")

        tour.handle(.lastFourChanged(isComplete: true))
        XCTAssertEqual(tour.step, .saveCard)

        tour.handle(.cardSaved)
        XCTAssertEqual(tour.step, .cardAdded)
        XCTAssertNil(tour.skipDestination, "这一章已经做完了，只剩「下一步」")
    }

    func testSaveDismissesBothSheets_TheirDisappearIsNotTreatedAsCancel() {
        startAddCardChapter()
        tour.handle(.templateListAppeared)
        tour.handle(.addCardAppeared(fromTemplate: true))
        tour.handle(.cardSaved)

        // 保存后 rootSheet = nil，两层 sheet 一起收起，消失事件随后才到
        tour.handle(.addCardDisappeared)
        tour.handle(.templateListDisappeared)

        XCTAssertEqual(tour.step, .cardAdded)
    }

    func testLastFourIsOptional_PrimaryButtonMovesOnToSave() {
        startAddCardChapter()
        tour.handle(.templateListAppeared)
        tour.handle(.addCardAppeared(fromTemplate: true))

        XCTAssertNotNil(TourStep.enterLastFour.primaryTitle)
        tour.advance()

        XCTAssertEqual(tour.step, .saveCard)
    }

    func testCustomPath_SkipsTheLastFourSpotlight() {
        startAddCardChapter()

        tour.handle(.addCardAppeared(fromTemplate: false))
        XCTAssertEqual(tour.step, .fillCustomCard)

        tour.handle(.cardSaved)
        XCTAssertEqual(tour.step, .cardAdded)
    }

    func testPrimaryButtonDoesNothing_OnStepsThatNeedARealTap() {
        startAddCardChapter()
        tour.advance()
        XCTAssertEqual(tour.step, .openTemplates)

        tour.handle(.templateListAppeared)
        tour.advance()
        XCTAssertEqual(tour.step, .pickTemplate)
    }

    // MARK: - 用户中途取消

    func testCancelAddCard_FallsBackToTemplateList() {
        startAddCardChapter()
        tour.handle(.templateListAppeared)
        tour.handle(.addCardAppeared(fromTemplate: true))

        tour.handle(.addCardDisappeared)
        XCTAssertEqual(tour.step, .pickTemplate, "模板列表还垫在下面，应该退回选卡这一步")

        tour.handle(.templateListDisappeared)
        XCTAssertEqual(tour.step, .openTemplates)

        // 再走一遍照样能走通
        tour.handle(.templateListAppeared)
        XCTAssertEqual(tour.step, .pickTemplate)
    }

    func testCancelOnSaveStep_AlsoFallsBack() {
        startAddCardChapter()
        tour.handle(.templateListAppeared)
        tour.handle(.addCardAppeared(fromTemplate: true))
        tour.handle(.lastFourChanged(isComplete: true))
        XCTAssertEqual(tour.step, .saveCard)

        tour.handle(.addCardDisappeared)

        XCTAssertEqual(tour.step, .pickTemplate)
    }

    func testCancelCustomAddCard_FallsBackToTheMenu() {
        startAddCardChapter()
        tour.handle(.addCardAppeared(fromTemplate: false))

        tour.handle(.addCardDisappeared)

        XCTAssertEqual(tour.step, .openTemplates, "自定义添加是从卡包页直接弹的，底下没有模板列表")
    }

    // MARK: - 跳过

    func testSkipInsideSheet_DismissesSheetsAndJumpsToReceiptChapter() {
        startAddCardChapter()
        tour.handle(.templateListAppeared)
        tour.handle(.addCardAppeared(fromTemplate: true))
        XCTAssertEqual(tour.sheetDismissRequest, 0)

        tour.skipChapter()

        XCTAssertEqual(tour.step, .cameraShutter)
        XCTAssertEqual(tour.sheetDismissRequest, 1)

        // sheet 收起时的消失事件不能把导览拽回添加卡片
        tour.handle(.addCardDisappeared)
        tour.handle(.templateListDisappeared)
        XCTAssertEqual(tour.step, .cameraShutter)
    }

    func testSkipOnMainScreen_DoesNotTouchSheets() {
        startAddCardChapter()

        tour.skipChapter()

        XCTAssertEqual(tour.step, .cameraShutter)
        XCTAssertEqual(tour.sheetDismissRequest, 0)
    }

    func testSkipIsHidden_WhenItWouldGoWhereNextGoes() {
        tour.start()
        XCTAssertNil(tour.skipDestination, "欢迎页的「跳过」是结束整个导览，不是跳章")

        tour.advance()
        XCTAssertEqual(tour.step, .openTemplates)
        XCTAssertEqual(tour.skipDestination, .cameraShutter)

        tour.skipChapter()
        XCTAssertEqual(tour.step, .cameraShutter)
        XCTAssertEqual(tour.skipDestination, .screenshotShortcut)

        // 下面几步「跳过」和「下一步」去同一个地方，只留「下一步」
        for step: TourStep in [.cameraImport, .screenshotShortcut, .bankSync, .finish] {
            tour.advance()
            XCTAssertEqual(tour.step, step)
            XCTAssertNil(tour.skipDestination, "\(step)")
        }
    }

    // MARK: - 讲解章节

    func testExplanatoryChapters_RunToFinishAndEnd() {
        startAddCardChapter()
        tour.handle(.addCardAppeared(fromTemplate: false))
        tour.handle(.cardSaved)

        for step: TourStep in [.cameraShutter, .cameraImport, .screenshotShortcut, .bankSync, .finish] {
            tour.advance()
            XCTAssertEqual(tour.step, step)
        }

        tour.advance()
        XCTAssertNil(tour.step)
        XCTAssertTrue(defaults.bool(forKey: OnboardingTour.seenKey))
    }

    // MARK: - 控件位置

    func testFrameIsOnlyReportedWhileTargetIsOnScreen() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        tour.updateFrame(rect, for: .cameraShutter)
        XCTAssertNil(tour.frame(for: .cameraShutter), "量到了但还没出现（比如没切过去的标签页）")

        tour.setVisible(true, target: .cameraShutter)
        XCTAssertEqual(tour.frame(for: .cameraShutter), rect)

        tour.setVisible(false, target: .cameraShutter)
        XCTAssertNil(tour.frame(for: .cameraShutter))

        // 切回来时 onGeometryChange 未必再回调：位置要留着，重新可见就能直接用
        tour.setVisible(true, target: .cameraShutter)
        XCTAssertEqual(tour.frame(for: .cameraShutter), rect)
    }

    // MARK: - 脚本自洽

    func testScriptIsConsistent() {
        for step in TourStep.allCases {
            switch step.style {
            case .spotlight:
                XCTAssertFalse(step.targets.isEmpty, "\(step) 是高亮步骤却没有目标")
            case .hint, .card:
                XCTAssertTrue(step.targets.isEmpty, "\(step) 不挖洞却声明了目标")
            }

            if step.host != .main {
                // sheet 里的步骤切标签页会把 sheet 底下的页面换掉
                XCTAssertNil(step.tab, "\(step) 在 sheet 里，不该切标签页")
            }

            if step.style == .card {
                XCTAssertNotNil(step.primaryTitle, "\(step) 是整屏卡片，没有按钮就出不去")
            }
        }
    }
}
