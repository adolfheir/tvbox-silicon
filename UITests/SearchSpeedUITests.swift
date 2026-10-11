import XCTest

final class SearchSpeedUITests: XCTestCase {
    @MainActor func testMultiSelectMediaSpeedComparisonSortingAndCancellation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "search", "-qaPage", "search:测速",
                               "-qaSubscription", "http://127.0.0.1:8776/speed-config.json", "-qaLegacyUI", "1",
                               "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let mode = app.buttons["search.speed.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 30), app.debugDescription)
        mode.tap()
        let fast = app.buttons["search.speed.select.qa-speed-fast.1"]
        let slow = app.buttons["search.speed.select.qa-speed-slow.1"]
        XCTAssertTrue(fast.waitForExistence(timeout: 10))
        fast.tap(); slow.tap()
        let start = app.buttons["search.speed.start"]
        XCTAssertTrue(start.isEnabled)
        start.tap()
        let fastResult = app.staticTexts["search.speed.result.qa-speed-fast.1"]
        let slowResult = app.staticTexts["search.speed.result.qa-speed-slow.1"]
        expectation(for: NSPredicate { _, _ in (Double(fastResult.value as? String ?? "") ?? 0) > 0 }, evaluatedWith: nil)
        expectation(for: NSPredicate { _, _ in (Double(slowResult.value as? String ?? "") ?? 0) > 0 }, evaluatedWith: nil)
        waitForExpectations(timeout: 30)
        let fastSpeed = try XCTUnwrap(Double(fastResult.value as? String ?? ""))
        let slowSpeed = try XCTUnwrap(Double(slowResult.value as? String ?? ""))
        XCTAssertGreaterThan(fastSpeed, slowSpeed)
        XCTAssertFalse(app.staticTexts["search.speed.result.qa-speed-error.1"].exists)
        app.buttons["search.speed.sort"].tap()
        XCTAssertTrue(fast.frame.minY < slow.frame.minY || (abs(fast.frame.minY-slow.frame.minY) < 2 && fast.frame.minX < slow.frame.minX))
        let comparison = XCTAttachment(screenshot: app.screenshot())
        comparison.name = "Selected media speeds sorted fastest first"; comparison.lifetime = .keepAlways; add(comparison)
        mode.tap()
        mode.tap()
        slow.tap(); start.tap()
        let stop = app.buttons["search.speed.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        expectation(for: NSPredicate(format: "value == %@", "测速已停止"), evaluatedWith: slowResult)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(slowResult.value as? String, "测速已停止")
        XCTAssertTrue(start.isEnabled)
        mode.tap()
    }
}
