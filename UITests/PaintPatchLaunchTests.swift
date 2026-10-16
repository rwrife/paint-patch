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

    func testCompareSelectAndTouchUpJourney() throws {
        launchApp()

        app.textFields["room.name"].tap()
        app.textFields["room.name"].typeText("Hall")
        dismissKeyboard()
        app.buttons["room.add"].tap()
        app.staticTexts["Hall"].tap()

        func addSample(_ label: String, code: String) {
            app.textFields["sample.label"].tap()
            app.textFields["sample.label"].typeText(label)
            app.textFields["sample.code"].tap()
            app.textFields["sample.code"].typeText(code)
            dismissKeyboard()
            app.buttons["sample.add"].tap()
            XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 5))
        }
        addSample("Alpha", code: "PPU18-15")
        addSample("Beta", code: "PPU37-12")

        app.buttons["workspace.open"].tap()
        // Explicit selection required: nothing is chosen automatically.
        XCTAssertEqual(app.staticTexts["workspace.selected"].label, "Selected: None")

        // Color-independent cue: card text states the selection, not just tint.
        app.buttons["workspace.choose.Alpha"].tap()
        XCTAssertEqual(app.staticTexts["workspace.selected"].label, "Selected: Alpha")

        // Touch-up with a blank lot keeps the lot unknown, never inferred.
        app.buttons["workspace.touchup"].tap()
        XCTAssertTrue(app.staticTexts["Alpha · Lot: Unknown"].waitForExistence(timeout: 5))

        // Revise: choosing Beta appends a new event; undo returns to None.
        let gallery = app.scrollViews["workspace.gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        gallery.swipeLeft()
        app.buttons["workspace.choose.Beta"].tap()
        XCTAssertEqual(app.staticTexts["workspace.selected"].label, "Selected: Beta")
        app.buttons["workspace.clear"].tap()
        XCTAssertEqual(app.staticTexts["workspace.selected"].label, "Selected: None")

        // Append-only history survives undo and relaunch (still shows Alpha, Beta, cleared).
        let directory = app.launchArguments.last!
        app.terminate()
        app.launchArguments = ["-PPTestContainerDirectory", directory]
        app.launch()
        app.staticTexts["Hall"].tap()
        app.buttons["workspace.open"].tap()
        XCTAssertEqual(app.staticTexts["workspace.selected"].label, "Selected: None")
        XCTAssertTrue(app.staticTexts["Alpha · Lot: Unknown"].waitForExistence(timeout: 5))
    }
}
