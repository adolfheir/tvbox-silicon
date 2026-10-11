import XCTest

/// Opt-in live-service acceptance. Run on an isolated simulator app; this test
/// performs three small read-only requests to the configured public service.
final class DanmakuUITests: XCTestCase {
    @MainActor func testSearchSelectAndDisableDanmaku() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "home", "-qaPage", "play-source:瓜子",
                               "-qaSubscription", "https://cdn.jsdelivr.net/gh/adolfheir/tvbox@master/fty.json",
                               "-danmakuAutoMatch", "0", "-qaPlayerControls", "1",
                               "-qaVideoQuery", "葬送的芙莉莲", "-qaDanmakuSettings", "1", "-qaMute", "1", "-qaLegacyUI", "1", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let control = app.buttons["player.danmaku"]
        let field = app.textFields["danmaku.keyword"]
        XCTAssertTrue(field.waitForExistence(timeout: 90), app.debugDescription)
        app.buttons["danmaku.search"].tap()
        let anime = app.buttons["danmaku.anime.17617"]
        XCTAssertTrue(anime.waitForExistence(timeout: 35), app.debugDescription)
        anime.tap()
        let episode = app.buttons["danmaku.episode.176170001"]
        XCTAssertTrue(episode.waitForExistence(timeout: 35), app.debugDescription)
        episode.tap()
        // Wait for the sheet to finish its dismissal before reopening it.
        let sheetGone = NSPredicate(format: "exists == false")
        expectation(for: sheetGone, evaluatedWith: app.textFields["danmaku.keyword"])
        waitForExpectations(timeout: 35)
        let more = app.buttons["player.more"]
        if !more.waitForExistence(timeout: 2) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).tap()
            XCTAssertTrue(more.waitForExistence(timeout: 5))
        }
        more.tap()
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        control.tap()
        let toggle = app.switches["danmaku.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        let loaded = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已加载")).firstMatch
        XCTAssertTrue(loaded.exists, app.debugDescription)
        XCTAssertFalse(loaded.label.contains("已加载 0 "))
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "Danmaku loaded settings"; settings.lifetime = .keepAlways
        add(settings)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let disabled = NSPredicate(format: "value == %@", "0")
        expectation(for: disabled, evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["完成"].tap()
        let video = XCTAttachment(screenshot: app.screenshot())
        video.name = "Danmaku video overlay"; video.lifetime = .keepAlways
        add(video)
    }
}
