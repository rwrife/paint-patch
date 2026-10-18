import Foundation
import XCTest
@testable import PaintPatchKit

final class InventoryCSVTests: XCTestCase {
    func testInventoryQuotesTextAndKeepsUnknownFactsExplicit() throws {
        var workspace = PaintWorkspace()
        let room = try workspace.recordRoom("Kitchen, north")
        _ = try workspace.recordCandidate(roomID: room.id, label: "Sample \"A\"", brand: "",
                                          code: "", finish: "", wallLocation: "Near\nwindow", canLot: "")
        let csv = try workspace.inventoryCSV()
        XCTAssertEqual(csv, "Room,Sample,Brand,Code,Finish,Patch location,Can lot\r\n" +
                             "\"Kitchen, north\",\"Sample \"\"A\"\"\",Unknown,Unknown,Unknown,\"Near\nwindow\",Unknown\r\n")
        XCTAssertFalse(csv.contains(room.id.uuidString))
        XCTAssertFalse(csv.contains("photos/"))
    }

    func testInventoryRejectsSpreadsheetFormulaPrefixAndControlCharacters() throws {
        var workspace = PaintWorkspace()
        let room = try workspace.recordRoom("=HYPERLINK(\"https://example.com\")")
        _ = try workspace.recordCandidate(roomID: room.id, label: "\t+SUM(1,2)", brand: "@cmd",
                                          code: "-1", finish: "\r=bad", wallLocation: "", canLot: "")
        let csv = try workspace.inventoryCSV()
        XCTAssertTrue(csv.contains("'=HYPERLINK"))
        XCTAssertTrue(csv.contains("'+SUM"))
        XCTAssertTrue(csv.contains("'@cmd"))
        XCTAssertTrue(csv.contains("'-1"))
        XCTAssertTrue(csv.contains("'=bad"))
        XCTAssertFalse(csv.contains("\t"))
        XCTAssertFalse(csv.contains("\r=bad"))
    }

    func testInventoryRefusesInvalidWorkspace() throws {
        var workspace = PaintWorkspace()
        workspace.candidates = [Candidate(roomID: UUID(), label: "orphan")]
        XCTAssertThrowsError(try workspace.inventoryCSV())
    }
}
