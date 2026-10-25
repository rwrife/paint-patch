import XCTest

final class PaintPatchLaunchTests: XCTestCase {
    private var app: XCUIApplication!

    /// Each run gets a fresh notebook directory (handled by `-PPTestContainerDirectory`).
    private func launchApp(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = extraArguments + ["-PPTestContainerDirectory",
                               NSTemporaryDirectory() + "pp-\(UUID().uuidString)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["app.title"].waitForExistence(timeout: 10))
    }

    /// Tap the actual Done key; a window-level press above the keyboard can leave focus active.
    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let done = app.keyboards.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Text fields must expose a Done key")
        done.tap()
        waitForNoKeyboard()
    }

    private func waitForNoKeyboard() {
        for _ in 0..<50 where app.keyboards.firstMatch.exists {
            usleep(100_000)
        }
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Keyboard must close before navigation")
    }

    /// Lazy List rows are absent from the AX tree until scrolled into view; reveal bounded, both directions.
    @discardableResult
    private func reveal(_ element: XCUIElement) -> XCUIElement {
        for _ in 0..<5 where !(element.exists && element.isHittable) { app.swipeUp() }
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeDown() }
        return element
    }

    private func revealText(_ text: XCUIElement) -> Bool {
        for _ in 0..<5 where !text.exists { app.swipeUp() }
        for _ in 0..<8 where !text.exists { app.swipeDown() }
        return text.exists
    }

    func testLaunchShowsNotebookTitle() {
        launchApp()
    }

    func testAccessibilityXXXLCanCreateRoomAndReachBackup() {
        // UIKit requires this raw category name; descriptive English names are ignored.
        let category = "UICTContentSizeCategoryAccessibilityXXXL"
        app = XCUIApplication()
        app.launchArguments = ["-PPTestContainerDirectory",
                               NSTemporaryDirectory() + "pp-\(UUID().uuidString)",
                               "-UIPreferredContentSizeCategoryName", category]
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = category
        app.launch()
        XCTAssertTrue(app.staticTexts["app.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["room.name"].isHittable)
        app.textFields["room.name"].tap()
        app.textFields["room.name"].typeText("Studio")
        dismissKeyboard()
        reveal(app.buttons["room.add"]).tap()
        XCTAssertTrue(revealText(app.staticTexts["Studio"]))
        let backup = reveal(app.buttons["app.backup"])
        XCTAssertTrue(backup.isHittable, "Backup must remain reachable at AX XXXL")
        backup.tap()
        XCTAssertTrue(reveal(app.buttons["backup.import"]).isHittable)
        XCTAssertFalse(app.buttons["backup.apply"].exists)
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
        XCTAssertTrue(revealText(app.staticTexts["Lighting: Morning daylight"]))

        // Revisions preserve linked observations and do not invent unknown finish.
        reveal(app.buttons["sample.edit.open"]).tap()
        app.textFields["edit.label"].tap()
        let existing = app.textFields["edit.label"].value as? String ?? "Sample A"
        app.textFields["edit.label"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        app.textFields["edit.label"].typeText("Revised A")
        dismissKeyboard()
        app.buttons["sample.save"].tap()
        waitForNoKeyboard()
        XCTAssertTrue(revealText(app.staticTexts["sample.current.label"]))
        XCTAssertEqual(app.staticTexts["sample.current.label"].label, "Label: Revised A")
        XCTAssertTrue(revealText(app.staticTexts["Lighting: Morning daylight"]))

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
            let labelField = app.textFields["sample.label"]
            for _ in 0..<3 where !(labelField.exists && labelField.isHittable) {
                app.swipeDown()
            }
            labelField.tap()
            labelField.typeText(label)
            app.textFields["sample.code"].tap()
            app.textFields["sample.code"].typeText(code)
            dismissKeyboard()
            app.buttons["sample.add"].tap()
            // Sample rows below the form are lazy; scroll to materialize the saved row.
            XCTAssertTrue(revealText(app.staticTexts[label]))
        }
        addSample("Alpha", code: "PPU18-15")
        addSample("Beta", code: "PPU37-12")

        let workspaceButton = app.buttons["workspace.open"]
        for _ in 0..<3 where !(workspaceButton.exists && workspaceButton.isHittable) {
            app.swipeUp()
        }
        reveal(workspaceButton).tap()
        // Explicit selection required: nothing is chosen automatically.
        XCTAssertEqual(reveal(app.staticTexts["workspace.selected"]).label, "Selected: None")

        // Color-independent cue: card text states the selection, not just tint.
        app.buttons["workspace.choose.Alpha"].tap()
        XCTAssertEqual(reveal(app.staticTexts["workspace.selected"]).label, "Selected: Alpha")

        // Touch-up with a blank lot keeps the lot unknown, never inferred.
        reveal(app.buttons["workspace.touchup"]).tap()
        XCTAssertTrue(revealText(app.staticTexts["Alpha · Lot: Unknown"]))

        // Revise: choosing Beta appends a new event; undo returns to None.
        let gallery = app.scrollViews["workspace.gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        gallery.swipeLeft()
        app.buttons["workspace.choose.Beta"].tap()
        XCTAssertEqual(reveal(app.staticTexts["workspace.selected"]).label, "Selected: Beta")
        reveal(app.buttons["workspace.clear"]).tap()
        XCTAssertEqual(reveal(app.staticTexts["workspace.selected"]).label, "Selected: None")

        // Append-only history survives undo and relaunch (still shows Alpha, Beta, cleared).
        let directory = app.launchArguments.last!
        app.terminate()
        app.launchArguments = ["-PPTestContainerDirectory", directory]
        app.launch()
        app.staticTexts["Hall"].tap()
        reveal(app.buttons["workspace.open"]).tap()
        XCTAssertEqual(reveal(app.staticTexts["workspace.selected"]).label, "Selected: None")
        XCTAssertTrue(revealText(app.staticTexts["Alpha · Lot: Unknown"]))
    }

    func testDeniedCameraPreservesManualObservationAndAccessibleFacts() {
        launchApp()
        app.textFields["room.name"].tap()
        app.textFields["room.name"].typeText("Den")
        dismissKeyboard()
        app.buttons["room.add"].tap()
        app.staticTexts["Den"].tap()
        app.textFields["sample.label"].tap()
        app.textFields["sample.label"].typeText("Unknown can")
        dismissKeyboard()
        app.buttons["sample.add"].tap()
        revealText(app.staticTexts["Unknown can"])
        app.staticTexts["Unknown can"].tap()
        XCTAssertEqual(app.staticTexts["sample.current.facts"].label,
                       "Code: Unknown · Finish: Unknown")

        // Relaunch same notebook with deterministic permission-denial injection, not simulator
        // camera absence; assert user still has manual path after denial.
        let directory = app.launchArguments.last!
        app.terminate()
        app.launchArguments = ["-PPTestContainerDirectory", directory, "-PPTestCameraDenied"]
        app.launch()
        app.staticTexts["Den"].tap()
        revealText(app.staticTexts["Unknown can"])
        app.staticTexts["Unknown can"].tap()
        reveal(app.buttons["observation.camera"]).tap()
        XCTAssertTrue(app.alerts["Notebook error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["Camera access is off. Enable it in Settings, or save notes / choose a photo instead."].exists)
        app.alerts.buttons["OK"].tap()
        app.textFields["observation.lighting"].tap()
        app.textFields["observation.lighting"].typeText("Warm lamp")
        dismissKeyboard()
        reveal(app.buttons["observation.save"]).tap()
        XCTAssertTrue(revealText(app.staticTexts["Lighting: Warm lamp"]))
    }

    /// Native file pickers are system UI and not driven here; the journey proves the screen is
    /// reachable and that restore needs an explicit file choice (nothing pending by default).
    func testBackupScreenReachableAndNothingPendingByDefault() {
        launchApp()
        XCTAssertTrue(revealText(app.staticTexts["Data & privacy"]) || reveal(app.buttons["app.backup"]).exists)
        reveal(app.buttons["app.backup"]).tap()
        XCTAssertTrue(app.buttons["backup.prepare"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.csv"].exists)
        XCTAssertTrue(app.buttons["backup.import"].exists)
        XCTAssertFalse(app.buttons["backup.apply"].exists, "No restore may be applicable before a previewed file")
    }

    /// Restore journey through the real preview/apply UI. The picked file is a launch-argument
    /// fixture (system pickers are not drivable); decode, preview, cancel and apply are real.
    func testRestorePreviewCancelThenApplyPersists() {
        launchApp(extraArguments: ["-PPTestRestoreFixture"])
        reveal(app.buttons["app.backup"]).tap()
        reveal(app.buttons["backup.import"]).tap()
        XCTAssertEqual(reveal(app.staticTexts["backup.preview.new"]).label, "Records to add: 2")
        XCTAssertFalse(app.staticTexts["backup.preview.conflict"].exists)

        // Cancel discards the preview; nothing is applicable and nothing was written.
        reveal(app.buttons["Cancel"]).tap()
        XCTAssertFalse(app.buttons["backup.apply"].exists)

        reveal(app.buttons["backup.import"]).tap()
        reveal(app.buttons["backup.apply"]).tap()
        for _ in 0..<50 where app.buttons["backup.apply"].exists { usleep(100_000) }
        XCTAssertFalse(app.buttons["backup.apply"].exists, "Preview clears after a successful apply")

        // Restored records are visible and survive relaunch of the same notebook.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(revealText(app.staticTexts["Restored Room"]))
        let directory = app.launchArguments.last!
        app.terminate()
        app.launchArguments = ["-PPTestContainerDirectory", directory]
        app.launch()
        XCTAssertTrue(revealText(app.staticTexts["Restored Room"]))
    }

    /// Photos picker is system-owned (no library permission to deny). The photo-less path must
    /// stay available and the screen must never ask for broad library access.
    func testPhotoPickerIsPermissionFreeAndManualPathRemains() {
        launchApp()
        app.textFields["room.name"].tap()
        app.textFields["room.name"].typeText("Loft")
        dismissKeyboard()
        app.buttons["room.add"].tap()
        app.staticTexts["Loft"].tap()
        app.textFields["sample.label"].tap()
        app.textFields["sample.label"].typeText("Loft can")
        dismissKeyboard()
        app.buttons["sample.add"].tap()
        XCTAssertTrue(revealText(app.staticTexts["Loft can"]))
        app.staticTexts["Loft can"].tap()
        XCTAssertTrue(reveal(app.buttons["observation.photo"]).exists)
        XCTAssertTrue(revealText(app.staticTexts["Photo access uses system picker only. No broad library permission needed."]))
        app.textFields["observation.lighting"].tap()
        app.textFields["observation.lighting"].typeText("North window")
        dismissKeyboard()
        reveal(app.buttons["observation.save"]).tap()
        XCTAssertTrue(revealText(app.staticTexts["Lighting: North window"]))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
