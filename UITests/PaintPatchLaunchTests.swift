import XCTest

final class PaintPatchLaunchTests: XCTestCase {
    private var app: XCUIApplication!

    /// Each run gets a fresh notebook directory (handled by `-PPTestContainerDirectory`).
    private func launchApp() {
        app = XCUIApplication()
        app.launchArguments = ["-PPTestContainerDirectory",
                               NSTemporaryDirectory() + "pp-\(UUID().uuidString)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["app.title"].waitForExistence(timeout: 10))
    }

    /// Decimal pads have no return key, so an open keyboard absorbs taps and swipes.
    private func dismissKeyboard() {
        let keyplane = app.keyboards.firstMatch
        if keyplane.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
                .withOffset(CGVector(dx: 0, dy: 8)).press(forDuration: 0.05)
        }
    }

    func testLaunchShowsNotebookTitle() {
        launchApp()
    }

    func testRecordRoomSampleAndLightingObservationJourney() {
        launchApp()

        app.textFields["room.name"].tap()
        app.textFields["room.name"].typeText("Bedroom")
        dismissKeyboard()
        app.buttons["room.add"].tap()
        XCTAssertTrue(app.staticTexts["Bedroom"].waitForExistence(timeout: 5))

        app.staticTexts["Bedroom"].tap()
        app.textFields["sample.label"].tap()
        app.textFields["sample.label"].typeText("Sample A")
        app.textFields["sample.code"].tap()
        app.textFields["sample.code"].typeText("PPU18-15")
        dismissKeyboard()
        app.buttons["sample.add"].tap()
        XCTAssertTrue(app.staticTexts["Sample A"].waitForExistence(timeout: 5))

        // Blank optional facts must surface as Unknown, never as a guessed match.
        XCTAssertTrue(app.staticTexts["Code: PPU18-15 · Finish: Unknown"].waitForExistence(timeout: 5))

        app.staticTexts["Sample A"].tap()
        app.textFields["observation.lighting"].tap()
        app.textFields["observation.lighting"].typeText("Morning daylight")
        dismissKeyboard()
        app.buttons["observation.save"].tap()
        XCTAssertTrue(app.staticTexts["Lighting: Morning daylight"].waitForExistence(timeout: 5))

        // Persistence proof: relaunch against the same directory, data survives.
        let directory = app.launchArguments.last!
        app.terminate()
        app.launchArguments = ["-PPTestContainerDirectory", directory]
        app.launch()
        XCTAssertTrue(app.staticTexts["Bedroom"].waitForExistence(timeout: 10))
    }
}
