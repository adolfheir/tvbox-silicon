import XCTest

final class PlayerControlsUITests: XCTestCase {
    @MainActor func testHorizontalSwipeSeeksWithoutChangingPlaybackState() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "history", "-qaPage", "play-source:qa-standard",
            "-qaSubscription", "http://127.0.0.1:8776/config.json", "-qaPlaybackProbe", "1",
            "-qaResetPlayerSettings", "1", "-qaStartAt", "90", "-autoPlayNextEpisode", "0",
            "-qaMute", "1", "-danmakuAutoMatch", "0", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let play = app.buttons["player.playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), app.debugDescription)
        waitValue(play, "playing")
        play.tap(); waitValue(play, "paused")
        let origin = position(app)
        drag(app, from: CGVector(dx: 0.2, dy: 0.33), to: CGVector(dx: 0.6, dy: 0.33))
        waitPosition(app, near: origin + 48)
        waitValue(play, "paused")
        XCTAssertFalse(app.otherElements["player.seekPreview"].exists)
        drag(app, from: CGVector(dx: 0.6, dy: 0.33), to: CGVector(dx: 0.2, dy: 0.33))
        waitPosition(app, near: origin)
        let beforeVertical = position(app)
        drag(app, from: CGVector(dx: 0.2, dy: 0.3), to: CGVector(dx: 0.2, dy: 0.6))
        XCTAssertEqual(position(app), beforeVertical, accuracy: 1)
        app.buttons["player.lock"].tap()
        XCTAssertTrue(app.buttons["player.unlock"].waitForExistence(timeout: 5))
        drag(app, from: CGVector(dx: 0.2, dy: 0.33), to: CGVector(dx: 0.6, dy: 0.33))
        XCTAssertEqual(position(app), beforeVertical, accuracy: 1)
        app.buttons["player.unlock"].tap(); waitValue(play, "paused")
        play.tap(); waitValue(play, "playing")
        // Let the ordinary chrome hide; seeking must still work on the video.
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: play)
        waitForExpectations(timeout: 8)
        let beforePlaying = position(app)
        drag(app, from: CGVector(dx: 0.2, dy: 0.33), to: CGVector(dx: 0.6, dy: 0.33))
        waitPosition(app, near: beforePlaying + 48, tolerance: 5)
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        waitValue(play, "playing")
        // Accessibility polling may outlast the 3.5-second chrome timeout.
        // The surface double-tap works with either visible or hidden controls.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).doubleTap()
        waitValue(play, "paused")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).doubleTap()
        waitValue(play, "playing")
        play.tap(); waitValue(play, "paused")
        app.sliders["player.progress"].adjust(toNormalizedSliderPosition: 0.1)
        waitPosition(app, near: 30)
        drag(app, from: CGVector(dx: 0.8, dy: 0.33), to: CGVector(dx: 0.1, dy: 0.33))
        waitPosition(app, near: 0, tolerance: 1)
        waitValue(play, "paused")
        app.sliders["player.progress"].adjust(toNormalizedSliderPosition: 0.95)
        // XCUI slider adjustment is approximate; only the swipe's final seek
        // is required to be exact at the duration boundary.
        expectation(for: NSPredicate { _, _ in self.position(app) >= 270 && self.position(app) < 300 }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        drag(app, from: CGVector(dx: 0.2, dy: 0.33), to: CGVector(dx: 0.6, dy: 0.33))
        waitPosition(app, near: 300, tolerance: 1)
        waitValue(play, "paused")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Horizontal seeking keeps paused playback and clamps to duration"
        image.lifetime = .keepAlways; add(image)
    }

    @MainActor private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        app.coordinate(withNormalizedOffset: from).press(forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: to), withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    @MainActor private func waitPosition(_ app: XCUIApplication, near expected: Double, tolerance: Double = 3) {
        expectation(for: NSPredicate { _, _ in abs(self.position(app) - expected) <= tolerance }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
    }

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
