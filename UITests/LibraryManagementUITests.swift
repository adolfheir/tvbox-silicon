import XCTest

final class LibraryManagementUITests: XCTestCase {
    @MainActor private func app(section: String, page: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let base = ProcessInfo.processInfo.environment["YINGXIA_QA_BASE"] ?? "http://127.0.0.1:8776"
        app.launchArguments = ["-qaSection", section, "-qaSubscription", base + "/config.json", "-qaIsolatedData", "1",
            "-qaPlayerControls", "1", "-qaPlaybackProbe", "1", "-qaMute", "1", "-autoPlayNextEpisode", "0",
            "-danmakuOfficialLookup", "0", "-danmakuServer", base, "-danmakuEnabled", "1", "-danmakuAutoMatch", "1", "-AppleLanguages", "(zh-Hans)"]
        if let page { app.launchArguments += ["-qaPage", page] }
        app.launchArguments += extra
        app.launch(); return app
    }
    @MainActor private func wait(_ element: XCUIElement, _ format: String, _ value: String, timeout: Double = 20) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        expectation(for: NSPredicate(format: format, value), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }
    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor func testSeriesSkipIsolationHistoryBulkDeletionAndContentCacheClear() throws {
        continueAfterFailure = false
        var app = app(section: "history", page: "play-source:qa-standard",
            extra: ["-qaResetHistory","1","-qaResetPlayerSettings","1","-qaResetCache","1","-qaStartAt","30"])
        wait(app.staticTexts["player.qa.danmaku"], "label == %@", "loaded")
        app.buttons["player.markIntro"].tap()
        XCTAssertTrue(app.alerts.buttons["确认"].waitForExistence(timeout: 10))
        app.alerts.buttons["确认"].tap()
        app.buttons["player.close"].tap()
        XCTAssertTrue(app.buttons["history.resume.1"].waitForExistence(timeout: 15))
        shot(app, "History keeps cached artwork and saved progress")
        app.terminate()

        app = self.app(section: "history", page: "play-source:qa-standard", extra: ["-qaEpisodeName","第 2 集"])
        wait(app.staticTexts["player.qa.danmaku"], "label == %@", "loaded")
        app.buttons["player.more"].tap()
        XCTAssertTrue(app.buttons["player.skip"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["player.skip"].tap()
        let intro = app.textFields["player.skip.intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 10))
        let savedIntro = try XCTUnwrap(intro.value as? String)
        XCTAssertNotEqual(savedIntro, "")
        shot(app, "The second episode shares only its own series intro")
        app.buttons["取消"].tap(); app.buttons["player.close"].tap(); app.terminate()

        app = self.app(section: "history", page: "play-source:qa-standard", extra: ["-qaVideoID","2"])
        XCTAssertTrue(app.buttons["player.more"].waitForExistence(timeout: 30))
        app.buttons["player.more"].tap()
        XCTAssertTrue(app.switches["player.autoSkip"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["player.skip"].exists, "An unrelated series must not inherit the first series times")
        shot(app, "A different series has no intro time")
        app.buttons["完成"].tap()
        wait(app.staticTexts["player.qa.position"], "value != %@", "0.0")
        app.buttons["player.close"].tap()
        XCTAssertTrue(app.buttons["history.resume.2"].waitForExistence(timeout: 15))
        app.buttons["history.manage"].tap()
        app.buttons["history.select.1"].tap()
        wait(app.buttons["history.select.1"], "value == %@", "1")
        app.buttons["history.deleteSelected"].tap()
        XCTAssertTrue(app.alerts.buttons["history.confirmDelete"].waitForExistence(timeout: 10))
        shot(app, "Confirm deletion of the selected series and content cache")
        app.buttons["history.confirmDelete"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["history.resume.1"])
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["history.resume.2"].exists)
        shot(app, "Selective history deletion keeps the other title")
        app.terminate()

        app = self.app(section: "settings", page: "cache")
        let clear = app.buttons["cache.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 20))
        clear.tap(); app.buttons["cache.confirmClear"].tap()
        XCTAssertTrue(app.staticTexts["单集弹幕：0"].waitForExistence(timeout: 10), app.debugDescription)
        shot(app, "Global cache clearing preserves saved history and settings")
    }
    @MainActor func testPinnedSourcesAppearOnHomeAndPersistAcrossLaunches() {
        continueAfterFailure = false
        var app = app(section: "sites", page: "site:qa-standard")
        let pin = app.buttons["source.pin.qa-standard"]
        XCTAssertTrue(pin.waitForExistence(timeout: 20))
        if pin.label == "取消置顶" { pin.tap() }
        pin.tap(); app.terminate()
        app = self.app(section: "home")
        let source = app.buttons["home.pinned.qa-standard"]
        XCTAssertTrue(source.waitForExistence(timeout: 20), app.debugDescription)
        shot(app, "Pinned source is visible before recommendations on the home page")
        source.tap()
        XCTAssertTrue(app.buttons["source.pin.qa-standard"].waitForExistence(timeout: 20))
        app.buttons["source.pin.qa-standard"].tap(); app.terminate()
        app = self.app(section: "home")
        XCTAssertFalse(app.buttons["home.pinned.qa-standard"].waitForExistence(timeout: 5))
    }
}
