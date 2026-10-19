import XCTest
@testable import PaintPatchKit

final class EditRecordsTests: XCTestCase {
    func testRevisingRecordsKeepsIdentityAndUnknownFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try WorkspaceRepository(directory: directory)
        let room = try store.change { try $0.recordRoom("Kitchen") }
        let sample = try store.change {
            try $0.recordCandidate(roomID: room.id, label: "First", brand: "Behr",
                                   code: "A1", finish: "Eggshell", wallLocation: "East", canLot: "lot 4")
        }
        let observation = try store.change {
            try $0.recordObservation(candidateID: sample.id, lighting: "Daylight", surface: "East", notes: "")
        }
        try store.change {
            try $0.renameRoom(room.id, to: "  Den  ")
            try $0.reviseCandidate(sample.id, label: "  Second  ", brand: "", code: " ",
                                   finish: "", wallLocation: "  West  ", canLot: "")
        }
        let reopened = try WorkspaceRepository(directory: directory).workspace
        XCTAssertEqual(reopened.rooms, [Room(id: room.id, name: "Den")])
        XCTAssertEqual(reopened.candidates[0].id, sample.id)
        XCTAssertEqual(reopened.candidates[0].label, "Second")
        XCTAssertNil(reopened.candidates[0].code)
        XCTAssertNil(reopened.candidates[0].finish)
        XCTAssertEqual(reopened.candidates[0].wallLocation, "West")
        XCTAssertEqual(reopened.observations[0], observation)
    }

    func testInvalidEditsCannotChangePersistedNotebook() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try WorkspaceRepository(directory: directory)
        let room = try store.change { try $0.recordRoom("Kitchen") }
        let sample = try store.change {
            try $0.recordCandidate(roomID: room.id, label: "First", brand: "", code: "",
                                   finish: "", wallLocation: "", canLot: "")
        }
        let before = store.workspace
        XCTAssertThrowsError(try store.change { try $0.renameRoom(room.id, to: " \n") })
        XCTAssertThrowsError(try store.change {
            try $0.reviseCandidate(sample.id, label: " ", brand: "", code: "", finish: "",
                                   wallLocation: "", canLot: "")
        })
        XCTAssertThrowsError(try store.change { try $0.renameRoom(UUID(), to: "Ghost") })
        XCTAssertEqual(store.workspace, before)
        XCTAssertEqual(try WorkspaceRepository(directory: directory).workspace, before)
    }
}
