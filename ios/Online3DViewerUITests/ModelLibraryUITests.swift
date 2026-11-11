import XCTest

final class ModelLibraryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var modelCard: XCUIElement { app.buttons["打开 SSBX-1106.3dm"] }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func saveScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The fixture is staged in FormatAudit and never touches the user's library.
    func testLoadingGuardAndCancellation() {
        app.launchArguments = ["--audit-case=55555555-5555-4555-8555-000000000001", "--ui-test-delay-post-read", "--test-run=loading-guard-ui"]
        app.launch()
        let guardView = app.otherElements["model-loading-guard"]
        XCTAssertTrue(guardView.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["cancel-loading"].exists)
        XCTAssertFalse(app.buttons["viewer-settings"].isEnabled)
        let start = guardView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: guardView.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        XCTAssertTrue(guardView.exists, "后台整理尚未结束时不能解锁")
        XCTAssertFalse(app.navigationBars["对象属性"].exists)
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: guardView)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 30), .completed, app.debugDescription)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["viewer-settings"].isEnabled)
        saveScreenshot("模型准备完成后解锁")

        app.terminate()
        app.launch()
        XCTAssertTrue(guardView.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["cancel-loading"].tap()
        XCTAssertTrue(app.navigationBars["模型库"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testSettingsPersistenceAndStorage() {
        app.launchArguments = ["--test-run=settings-ui"]
        app.launch()
        let settings = app.buttons["viewer-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10), app.debugDescription)
        let background = app.buttons["setting-background"]
        XCTAssertTrue(background.waitForExistence(timeout: 5), app.debugDescription)
        background.tap()
        app.buttons["深色"].tap()
        app.buttons["settings-storage"].tap()
        XCTAssertTrue(app.navigationBars["存储管理"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars["存储管理"].buttons["完成"].tap()
        app.navigationBars["设置"].buttons["完成"].tap()
        app.terminate()
        app.launch()
        app.buttons["viewer-settings"].tap()
        XCTAssertTrue(app.buttons["setting-background"].label.contains("深色"), app.debugDescription)
        app.buttons["setting-background"].tap()
        app.buttons["白色"].tap()
        app.navigationBars["设置"].buttons["完成"].tap()
        saveScreenshot("设置恢复默认")
    }

    func testImportGuidanceAndMissingCompanions() {
        app.launchArguments = ["--audit-case=22222222-2222-4222-8222-000000000101", "--test-run=missing-texture-ui"]
        app.launch()
        let details = app.buttons["cad-coverage-issues"]
        XCTAssertTrue(details.waitForExistence(timeout: 40), app.debugDescription)
        details.tap()
        XCTAssertTrue(app.navigationBars["显示说明"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "CesiumLogoFlat.png")).firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "配套文件")).firstMatch.exists, app.debugDescription)
        saveScreenshot("缺少贴图及处理建议")
        app.terminate()

        app.launchArguments = ["--audit-case=22222222-2222-4222-8222-000000000102", "--test-run=missing-buffer-ui"]
        app.launch()
        let failure = app.alerts["无法完成操作"]
        XCTAssertTrue(failure.waitForExistence(timeout: 40), app.debugDescription)
        XCTAssertTrue(failure.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "配套文件")).firstMatch.exists, app.debugDescription)
        XCTAssertTrue(failure.buttons["重新选择文件"].exists, app.debugDescription)
        failure.buttons["确定"].tap()
        app.terminate()

        app.launchArguments = ["--sample=O3DV-unsupported.max", "--test-run=unsupported-import-ui"]
        app.launch()
        XCTAssertTrue(failure.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(failure.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", ".MAX")).firstMatch.exists, app.debugDescription)
        XCTAssertTrue(failure.buttons["重新选择文件"].exists, app.debugDescription)
        failure.buttons["重新选择文件"].tap()
        let pickerCancel = app.buttons["取消"]
        XCTAssertTrue(pickerCancel.waitForExistence(timeout: 10), app.debugDescription)
        if pickerCancel.exists { pickerCancel.tap() }
        XCTAssertTrue(app.navigationBars["模型库"].exists)
        saveScreenshot("不支持格式的处理建议")
    }

    func testCadCoverageAndLicenses() {
        // Generated drawing is isolated from the persistent user library.
        app.launchArguments = ["--audit-case=99999999-9999-4999-8999-000000000101", "--test-run=cad-ui"]
        app.launch()
        let details=app.buttons["cad-coverage-issues"]
        XCTAssertTrue(details.waitForExistence(timeout:30),app.debugDescription)
        details.tap()
        XCTAssertTrue(app.navigationBars["显示说明"].waitForExistence(timeout:5),app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","系统替代字体")).firstMatch.exists,app.debugDescription)
        saveScreenshot("CAD字体替代说明")
        app.buttons["完成"].tap()
        app.buttons["show-library"].tap()
        app.buttons["storage-management"].tap()
        app.buttons["开源许可"].tap()
        XCTAssertTrue(app.buttons["导出 CAD 读取器对应源码"].waitForExistence(timeout:5),app.debugDescription)
        app.buttons["CAD 读取器及 Rust 依赖"].tap()
        XCTAssertTrue(app.navigationBars["CAD 读取器及 Rust 依赖"].waitForExistence(timeout:5))
        saveScreenshot("CAD开源许可")
    }

    /// Exercises real touch navigation on the most recently opened 3DM model.
    func testRecent3dmDragRemainsVisible() throws {
        app.launchArguments = ["--test-run=recent-3dm-drag"]
        app.launch()
        let recent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH[c] %@", "打开 ", ".3dm")).firstMatch
        guard recent.waitForExistence(timeout: 20) else { throw XCTSkip("模型库中没有 3DM 模型") }
        recent.tap()
        let loaded = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已显示 ")).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 120), app.debugDescription)
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        let center = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for point in [CGVector(dx: 0.64, dy: 0.55), CGVector(dx: 0.4, dy: 0.43), CGVector(dx: 0.56, dy: 0.45)] {
            center.press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: point))
            XCTAssertTrue(loaded.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
        saveScreenshot("真实模型手势旋转")
    }

    func testPagedViewOnRecent3dm() throws {
        app.launchArguments = ["--ui-test-geometry-budget=25165824", "--test-run=paged-progress-ui"]
        app.launch()
        let recent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH[c] %@", "打开 ", ".3dm")).firstMatch
        guard recent.waitForExistence(timeout: 20) else { throw XCTSkip("模型库中没有 3DM 模型") }
        recent.tap()
        let loaded = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已显示 ")).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 120), app.debugDescription)
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        let center = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.58)))
        XCTAssertTrue(loaded.waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        saveScreenshot("低内存旋转完成")
    }

    private func waitForModel(cached: Bool? = nil) {
        let text = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已显示 683 / 683 个对象")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 45), app.debugDescription)
        if let cached { XCTAssertEqual(text.label.contains("缓存打开"), cached) }
    }

    private func goHome() {
        app.buttons["show-library"].tap()
        XCTAssertTrue(modelCard.waitForExistence(timeout: 10))
    }

    private func clearCaches() {
        app.buttons["storage-management"].tap()
        let clear = app.buttons["clear-all-cache"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        if clear.isEnabled {
            clear.tap()
            app.buttons["清理缓存"].tap()
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: clear)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 20), .completed)
        }
        saveScreenshot("存储管理")
        app.buttons["完成"].tap()
    }

    func testLibraryCacheAndCancellation() {
        app.launchArguments = ["--document=SSBX-1106.3dm", "--test-run=library-ui-workflow"]
        app.launch()
        waitForModel()
        saveScreenshot("首次打开模型")
        // Give the small thumbnail render time to finish before leaving the viewer.
        Thread.sleep(forTimeInterval: 1)
        goHome()
        saveScreenshot("模型库首页")
        modelCard.tap()
        waitForModel(cached: true)
        goHome()
        clearCaches()
        XCTAssertTrue(modelCard.exists, "清理缓存不应删除模型")
        modelCard.tap()
        waitForModel(cached: false)
        goHome()
        clearCaches()
        modelCard.tap()
        let cancel = app.buttons["cancel-loading"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(modelCard.waitForExistence(timeout: 10), "取消应返回模型库")
        XCTAssertFalse(app.alerts.firstMatch.exists, "取消不应显示失败弹窗")
        saveScreenshot("取消后返回模型库")
        modelCard.tap()
        waitForModel()
        saveScreenshot("取消后重新打开成功")
        goHome()
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(modelCard.waitForExistence(timeout: 10), "模型库应在重启后保留")
        saveScreenshot("重启后模型库")
    }

    func testDeleteImportedModel() {
        app.launchArguments = ["--sample=utah_teapot.stl", "--test-run=library-ui-delete"]
        app.launch()
        XCTAssertTrue(app.staticTexts["模型已打开"].waitForExistence(timeout: 30))
        app.buttons["show-library"].tap()
        let card = app.buttons["打开 utah_teapot.stl"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        app.buttons["utah_teapot.stl 的更多操作"].tap()
        app.buttons["删除模型"].tap()
        app.buttons["删除 utah_teapot.stl"].tap()
        XCTAssertTrue(modelCard.waitForExistence(timeout: 10))
        XCTAssertFalse(card.exists, "确认删除后模型卡片应移除")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        saveScreenshot("删除模型后")
    }

    /// Generated fixtures keep this test independent of any user's model.
    func testBoundedPagingInteractionAndLifecycle() {
        for (suffix,count) in [("101",3),("102",3),("103",1),("104",3)] {
            app.launchArguments = ["--audit-case=11111111-1111-4111-8111-000000000\(suffix)", "--test-run=pager-ui-\(suffix)"]
            app.launch()
            let loaded = suffix == "104" ? app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@","几何已显示 · 缺少配套文件：")).firstMatch : app.staticTexts["已显示 \(count) / \(count) 个对象"]
            XCTAssertTrue(loaded.waitForExistence(timeout: 40),app.debugDescription)
            let web = app.webViews.firstMatch
            let center = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.5))
            center.tap()
            XCTAssertTrue(app.navigationBars["对象属性"].waitForExistence(timeout: 15),app.debugDescription)
            app.buttons["完成"].tap()
            XCTAssertTrue(loaded.waitForExistence(timeout: 25),app.debugDescription)
            center.press(forDuration: 0.05,thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.8,dy: 0.65)))
            XCTAssertTrue(loaded.waitForExistence(timeout: 25),app.debugDescription)
            web.pinch(withScale: 1.2,velocity: 1)
            XCTAssertTrue(loaded.waitForExistence(timeout: 25),app.debugDescription)
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(loaded.waitForExistence(timeout: 25),app.debugDescription)
            XCTAssertFalse(app.alerts.firstMatch.exists)
            Thread.sleep(forTimeInterval: 3)
            XCTAssertTrue(loaded.exists,"完成后的状态栏不应触发循环重绘")
            saveScreenshot("分批显示旋转和前台恢复-\(suffix)")
            app.terminate()
        }
    }

    /// Requires the isolated 123.fbx fixture staged by audit_work_models.py.
    func testNativeFormatInteractionAndCancel() {
        app.launchArguments = ["--audit-case=2316DD79-AD29-5304-BAC5-A5F243B5AB5D", "--test-run=native-format-interaction"]
        app.launch()
        let loaded = app.staticTexts["已显示 99890 / 99890 个对象"]
        XCTAssertTrue(loaded.waitForExistence(timeout: 120), app.debugDescription)
        saveScreenshot("FBX包含全部裁剪曲面")
        let web = app.webViews.firstMatch
        let center = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)))
        center.press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        web.pinch(withScale: 1.5, velocity: 1)
        XCTAssertTrue(loaded.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        saveScreenshot("FBX旋转缩放后")
        app.buttons["图层"].tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "1 个图层 ·")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(summary.label.replacingOccurrences(of: ",", with: "").contains("99890 个对象"))
        saveScreenshot("FBX真实对象列表")
        app.terminate()
        app.launch()
        let cancel = app.buttons["cancel-loading"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        cancel.tap()
        XCTAssertTrue(app.navigationBars["模型库"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        saveScreenshot("FBX取消后返回模型库")
    }
}
