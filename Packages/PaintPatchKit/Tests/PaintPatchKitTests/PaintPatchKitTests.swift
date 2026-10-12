import XCTest
@testable import PaintPatchKit

final class PaintPatchKitTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(PaintPatchKit.self)
    }
}
