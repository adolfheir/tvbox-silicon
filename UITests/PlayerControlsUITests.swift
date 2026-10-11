import XCTest

final class PlayerControlsUITests: XCTestCase {
    @MainActor func testResponsiveTransportSelectionAutoAdvanceAndWakeLock() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let common = ["-qaSection", "history", "-qaPage", "play-source:qa-standard",
                      "-qaSubscription", "http://127.0.0.1:8776/config.json", "-qaPlayerControls", "1",
                      "-qaPlaybackProbe", "1", "-qaMute", "1", "-danmakuAutoMatch", "0",
                      "-AppleLanguages", "(zh-Hans)"]
        app.launchArguments = common + ["-qaResetPlayerSettings", "1", "-qaStartAt", "30", "-autoPlayNextEpisode", "1"]
        app.launch()
        let play = app.buttons["player.playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), app.debugDescription)
        waitValue(play, "playing")
        app.buttons["player.more"].tap()
        let autoSkip = app.switches["player.autoSkip"]
        XCTAssertTrue(autoSkip.waitForExistence(timeout: 10))
        XCTAssertTrue(autoSkip.isEnabled)
        XCTAssertFalse(app.buttons["player.skip"].exists)
        XCTAssertFalse(app.buttons["player.skip.outroTime"].exists)
        autoSkip.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        waitValue(autoSkip, "1")
        app.buttons["完成"].tap()
        waitValue(play, "playing")
        for _ in 0..<4 {
            play.tap(); waitValue(play, "paused")
            play.tap(); waitValue(play, "playing")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).doubleTap()
        waitValue(play, "paused")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).doubleTap()
        waitValue(play, "playing")
        let introButton = app.buttons["player.markIntro"]
        XCTAssertEqual(introButton.label, "片头")
        XCTAssertGreaterThan(introButton.frame.midX, app.frame.width / 2)
        XCTAssertLessThan(introButton.frame.midY, app.frame.height / 5)
        let beforeMark = position(app)
        introButton.tap()
        let confirm = app.alerts.buttons["确认"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isEnabled)
        let markImage = XCTAttachment(screenshot: app.screenshot())
        markImage.name = "Intro confirmation pauses playback"; markImage.lifetime = .keepAlways; add(markImage)
        Thread.sleep(forTimeInterval: 3)
        confirm.tap()
        waitValue(play, "playing")
        XCTAssertLessThan(position(app), beforeMark + 3.5, "Playback must remain paused while confirming")
        app.sliders["player.progress"].adjust(toNormalizedSliderPosition: 0.4)
        expectation(for: NSPredicate { _, _ in self.position(app) >= 110 }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        play.tap(); waitValue(play, "paused")
        let before = position(app)
        Thread.sleep(forTimeInterval: 6)
        XCTAssertEqual(position(app), before, accuracy: 0.5)
        XCTAssertEqual(app.staticTexts["player.qa.awake"].value as? String, "1")
        play.tap(); waitValue(play, "playing")
        app.buttons["player.markOutro"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertFalse(confirm.isEnabled, "An early outro mark must be rejected")
        app.alerts.buttons["取消"].tap()
        waitValue(play, "playing")
        app.sliders["player.progress"].adjust(toNormalizedSliderPosition: 0.85)
        expectation(for: NSPredicate { _, _ in self.position(app) >= 250 }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        app.buttons["player.markOutro"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        waitTitle(app, containing: "第 2 集")
        waitValue(play, "playing")
        app.buttons["player.lock"].tap()
        XCTAssertTrue(app.buttons["player.unlock"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.buttons["player.unlock"].frame.midX, app.frame.width / 2)
        XCTAssertFalse(play.exists)
        XCTAssertFalse(app.buttons["player.episodes"].exists)
        let lockedImage = XCTAttachment(screenshot: app.screenshot())
        lockedImage.name = "Locked player only exposes unlock"; lockedImage.lifetime = .keepAlways; add(lockedImage)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).doubleTap()
        app.buttons["player.unlock"].tap()
        waitValue(play, "playing")
        let backgroundPosition = position(app)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        waitValue(play, "paused")
        XCTAssertLessThanOrEqual(position(app), backgroundPosition + 2.5)
        let foregroundPosition = position(app)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(position(app), foregroundPosition, accuracy: 0.5)
        XCTAssertEqual(app.staticTexts["player.qa.awake"].value as? String, "1")
        play.tap(); waitValue(play, "playing")
        app.buttons["player.episodes"].tap()
        let third = app.buttons["player.episode.第 3 集"]
        XCTAssertTrue(third.waitForExistence(timeout: 10))
        third.tap()
        waitTitle(app, containing: "第 3 集")
        app.buttons["player.next"].tap()
        waitTitle(app, containing: "第 4 集")
        app.buttons["player.more"].tap()
        XCTAssertTrue(app.buttons["player.skip"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["player.danmaku"].exists)
        XCTAssertTrue(app.buttons["player.skip.outroTime"].exists)
        XCTAssertEqual(app.switches["player.autoSkip"].value as? String, "1")
        XCTAssertFalse(app.staticTexts["音量"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Player options consolidate infrequent actions"; image.lifetime = .keepAlways; add(image)
        app.buttons["完成"].tap()
        app.buttons["player.close"].tap()
        let idle = app.staticTexts["app.qa.awake"]
        XCTAssertTrue(idle.waitForExistence(timeout: 10))
        waitValue(idle, "0")
        app.terminate()

        app.launchArguments = common + ["-qaStartAt", "298", "-autoPlayNextEpisode", "1"]
        app.launch()
        waitTitle(app, containing: "第 2 集", timeout: 40)
        XCTAssertLessThan(position(app), 90, "The new episode must not inherit the old resume position")
        app.terminate()

        app.launchArguments = common + ["-qaStartAt", "298", "-qaEpisodeName", "第 36 集", "-autoPlayNextEpisode", "1"]
        app.launch()
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        waitAtEnd(app)
        waitValue(play, "paused", timeout: 20)
        waitTitle(app, containing: "第 36 集")
        XCTAssertFalse(app.buttons["player.next"].isEnabled)
        XCTAssertEqual(app.staticTexts["player.qa.awake"].value as? String, "1")
        app.terminate()

        app.launchArguments = common + ["-qaStartAt", "298", "-autoPlayNextEpisode", "0"]
        app.launch()
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        waitAtEnd(app)
        waitValue(play, "paused", timeout: 20)
        waitTitle(app, containing: "第 1 集")
    }

    @MainActor private func waitValue(_ element: XCUIElement, _ value: String, timeout: Double = 5) {
        expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }
    @MainActor private func waitTitle(_ app: XCUIApplication, containing value: String, timeout: Double = 25) {
        let title = app.staticTexts["player.title"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        expectation(for: NSPredicate(format: "label CONTAINS %@", value), evaluatedWith: title)
        waitForExpectations(timeout: timeout)
    }
    @MainActor private func position(_ app: XCUIApplication) -> Double {
        Double(app.staticTexts["player.qa.position"].value as? String ?? "") ?? -1
    }
    @MainActor private func waitAtEnd(_ app: XCUIApplication) {
        expectation(for: NSPredicate { _, _ in self.position(app) >= 299.5 }, evaluatedWith: nil)
        waitForExpectations(timeout: 30)
    }
}
