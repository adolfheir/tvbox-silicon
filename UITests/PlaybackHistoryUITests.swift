import XCTest

/// Deterministic media tests run only in the isolated simulator app. The final
/// device acceptance separately uses the user's real subscription and stream.
final class PlaybackHistoryUITests: XCTestCase {
    @MainActor func testSkipSettingsValidationPersistenceAndHistoryResume() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let common = ["-qaSubscription", "http://127.0.0.1:8776/config.json", "-qaPlayerControls", "1",
                      "-danmakuAutoMatch", "0", "-autoPlayNextEpisode", "0",
                      "-qaPlaybackProbe", "1", "-qaMute", "1", "-qaLegacyUI", "1", "-AppleLanguages", "(zh-Hans)"]
        app.launchArguments = common + ["-qaSection", "history", "-qaPage", "play-source:qa-standard", "-qaStartAt", "30", "-qaResetHistory", "1", "-qaResetPlayerSettings", "1"]
        app.launch()
        waitForPosition(app, minimum: 32)
        app.buttons["player.markIntro"].tap()
        let confirm = app.alerts.buttons["确认"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        app.buttons["player.more"].tap()
        app.buttons["player.skip"].tap()
        let mark = app.buttons["player.skip.markIntro"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10), app.debugDescription)
        mark.tap()
        let intro = app.textFields["player.skip.intro"]
        let introText = try XCTUnwrap(intro.value as? String)
        let outro = app.textFields["player.skip.outro"]
        outro.tap()
        outro.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (outro.value as? String ?? "").count) + "00:10")
        let save = app.buttons["player.skip.save"]
        XCTAssertFalse(save.isEnabled, "An outro that consumes nearly the whole video must not save")
        XCTAssertTrue(app.staticTexts["player.skip.validation"].exists)
        outro.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "04:40")
        XCTAssertTrue(save.isEnabled, app.debugDescription)
        save.tap()
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 10))
        waitForPosition(app, minimum: 34)
        let play = app.buttons["player.playPause"]
        play.tap()
        expectation(for: NSPredicate(format: "value == %@", "paused"), evaluatedWith: play)
        waitForExpectations(timeout: 10)
        let saved = try XCTUnwrap(Double(app.staticTexts["player.qa.position"].value as? String ?? ""))
        app.buttons["player.close"].tap()
        let history = app.buttons["history.resume.1"]
        XCTAssertTrue(history.waitForExistence(timeout: 10), app.debugDescription)
        let historyImage = XCTAttachment(screenshot: app.screenshot())
        historyImage.name = "Playback history with saved progress"; historyImage.lifetime = .keepAlways
        add(historyImage)

        // A fresh application process must load history and re-resolve the episode.
        app.terminate()
        app.launchArguments = common + ["-qaSection", "history"]
        app.launch()
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        history.tap()
        waitForPosition(app, minimum: saved - 1)
        let resume = app.staticTexts["player.qa.resume"]
        expectation(for: NSPredicate { _, _ in
            (Double(resume.value as? String ?? "") ?? -1) >= 0
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        let restored = try XCTUnwrap(Double(resume.value as? String ?? ""))
        XCTAssertEqual(restored, saved, accuracy: 2)
        app.buttons["player.more"].tap()
        app.buttons["player.skip"].tap()
        XCTAssertTrue(intro.waitForExistence(timeout: 10))
        XCTAssertEqual(intro.value as? String, introText)
        XCTAssertEqual(outro.value as? String, "04:40")
        app.buttons["取消"].tap()
        app.buttons["player.close"].tap()

        // Saved settings apply to the next play-through: intro first, then outro.
        app.terminate()
        app.launchArguments = common + ["-qaSection", "history", "-qaPage", "play-source:qa-standard"]
        app.launch()
        waitForPosition(app, minimum: 30)
        app.buttons["player.close"].tap()
        app.terminate()
        app.launchArguments = common + ["-qaSection", "history", "-qaPage", "play-source:qa-standard", "-qaStartAt", "281"]
        app.launch()
        waitForPosition(app, minimum: 299)
        let complete = XCTAttachment(screenshot: app.screenshot())
        complete.name = "Outro automatically skipped"; complete.lifetime = .keepAlways
        add(complete)
        app.buttons["player.close"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已看完")).firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor private func waitForPosition(_ app: XCUIApplication, minimum: Double, timeout: Double = 30) {
        let field = app.staticTexts["player.qa.position"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), app.debugDescription)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = field.value as? String, let position = Double(value), position >= minimum { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("Expected position >= \(minimum), got \(String(describing: field.value)). \(app.debugDescription)")
    }
}
