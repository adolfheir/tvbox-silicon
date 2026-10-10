import XCTest

final class DanmakuAutomaticUITests: XCTestCase {
    @MainActor func testAutomaticEpisodeMatchAndSilentAbsenceOrFailure() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let common = ["-qaSection", "history", "-qaPage", "play-source:qa-standard",
                      "-qaSubscription", "http://127.0.0.1:8776/config.json", "-qaPlayerControls", "1",
                      "-qaPlaybackProbe", "1", "-qaMute", "1", "-qaLegacyUI", "1",
                      "-danmakuAutoMatch", "1", "-danmakuEnabled", "1", "-AppleLanguages", "(zh-Hans)"]
        app.launchArguments = common + ["-danmakuServer", "http://127.0.0.1:8776"]
        app.launch()
        let state = app.staticTexts["player.qa.danmaku"]
        XCTAssertTrue(state.waitForExistence(timeout: 30), app.debugDescription)
        expectation(for: NSPredicate(format: "label == %@", "loaded"), evaluatedWith: state)
        waitForExpectations(timeout: 15)
        XCTAssertEqual(state.value as? String, "3")
        XCTAssertEqual(app.alerts.count, 0)
        app.terminate()

        app.launchArguments = common + ["-danmakuServer", "http://127.0.0.1:8776", "-qaEpisodeName", "第 3 集"]
        app.launch()
        XCTAssertTrue(state.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "label == %@", "unmatched"), evaluatedWith: state)
        waitForExpectations(timeout: 15)
        XCTAssertEqual(state.value as? String, "0")
        XCTAssertEqual(app.alerts.count, 0)
        app.terminate()

        app.launchArguments = common + ["-danmakuServer", "http://127.0.0.1:8776/failure"]
        app.launch()
        XCTAssertTrue(state.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "label == %@", "unavailable"), evaluatedWith: state)
        waitForExpectations(timeout: 15)
        XCTAssertEqual(state.value as? String, "0")
        XCTAssertEqual(app.alerts.count, 0)
        let position = app.staticTexts["player.qa.position"]
        expectation(for: NSPredicate(format: "value != %@", "0.0"), evaluatedWith: position)
        waitForExpectations(timeout: 10)
    }
}
