import XCTest

final class PaintPatchLaunchTests: XCTestCase {
    func testLaunchShowsNotebookTitle() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["app.title"].waitForExistence(timeout: 10))
    }
}
