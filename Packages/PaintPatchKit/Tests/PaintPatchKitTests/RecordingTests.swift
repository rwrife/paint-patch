import XCTest
@testable import PaintPatchKit

final class RecordingTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testBlankFactsNormalizeToUnknown() {
        XCTAssertNil(paintFact("   \n "))
        XCTAssertEqual(paintFact(" PPU18-15 "), "PPU18-15")
    }

    func testRecordingTrimsAndKeepsUnknownFieldsUnknown() throws {
        let room = Room(name: "Hall")
        var ws = PaintWorkspace()
        ws.rooms = [room]
        let candidate = try ws.recordCandidate(roomID: room.id, label: " Sample A ", brand: "  ",
                                               code: "PPU18-15", finish: "", wallLocation: "North",
                                               canLot: "  ")
        XCTAssertEqual(candidate.label, "Sample A")
        XCTAssertNil(candidate.brand)
        XCTAssertEqual(candidate.code, "PPU18-15")
        XCTAssertNil(candidate.finish)
        XCTAssertNil(candidate.canLot)
        let observation = try ws.recordObservation(candidateID: candidate.id, lighting: " ",
                                                   surface: "Patch", notes: "x", observedAt: Date())
        XCTAssertNil(observation.lighting)
        XCTAssertNil(try? ws.recordCandidate(roomID: room.id, label: "  ", brand: "", code: "",
                                             finish: "", wallLocation: "", canLot: ""))
        XCTAssertThrowsError(try ws.recordCandidate(roomID: UUID(), label: "ghost", brand: "",
                                                    code: "", finish: "", wallLocation: "", canLot: ""))
        XCTAssertThrowsError(try ws.recordObservation(candidateID: UUID(), lighting: "a",
                                                      surface: "", notes: ""))
    }

    func testRepositoryRoundTripAndCorruptFileUntouched() throws {
        let directory = try tempDirectory()
        let repository = try WorkspaceRepository(directory: directory)
        let room = try repository.change { try $0.recordRoom("Kitchen") }
        _ = try repository.change {
            try $0.recordCandidate(roomID: room.id, label: "A", brand: "Behr", code: "PPU18-15",
                                   finish: "Eggshell", wallLocation: "", canLot: "")
        }
        let reopened = try WorkspaceRepository(directory: directory)
        XCTAssertEqual(reopened.workspace.rooms, [room])
        XCTAssertEqual(reopened.workspace.candidates.count, 1)

        let file = directory.appendingPathComponent("workspace.json")
        try "not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkspaceRepository(directory: directory))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
    }

    func testFailedEditKeepsMemoryAndDiskUnchanged() throws {
        let directory = try tempDirectory()
        let repository = try WorkspaceRepository(directory: directory)
        let room = try repository.change { try $0.recordRoom("Kitchen") }
        let before = repository.workspace
        XCTAssertThrowsError(try repository.change { ws in
            _ = try ws.recordCandidate(roomID: room.id, label: "ok", brand: "", code: "",
                                       finish: "", wallLocation: "", canLot: "")
            ws.candidates[ws.candidates.count - 1].roomID = UUID() // dangling
        })
        XCTAssertEqual(repository.workspace, before)
        let reopened = try WorkspaceRepository(directory: directory)
        XCTAssertEqual(reopened.workspace, before)
    }

    func testAddPhotoWritesFileAndRegistrationRollbackLeavesNoOrphan() throws {
        let directory = try tempDirectory()
        let repository = try WorkspaceRepository(directory: directory)
        let photo = try repository.addPhoto(Data([0xFF, 0xD8]))
        XCTAssertEqual(try Data(contentsOf: repository.photoURL(photo)), Data([0xFF, 0xD8]))
        XCTAssertTrue(repository.workspace.photos.contains(photo))

        // Force registration failure after the file write via a duplicate id.
        let clash = PhotoReference(id: photo.id, fileName: "clash.jpg")
        XCTAssertThrowsError(try repository.change { try $0.addPhoto(clash) })
        XCTAssertEqual(try WorkspaceRepository(directory: directory).workspace.photos, [photo])
    }

    func testPhotoOnlyObservationLinksAndRemovalClearsThem() throws {
        let directory = try tempDirectory()
        let repository = try WorkspaceRepository(directory: directory)
        let room = try repository.change { try $0.recordRoom("Bedroom") }
        let candidate = try repository.change {
            try $0.recordCandidate(roomID: room.id, label: "A", brand: "", code: "",
                                   finish: "", wallLocation: "", canLot: "")
        }
        let photo = try repository.addPhoto(Data([0xFF]))
        _ = try repository.change {
            try $0.recordObservation(candidateID: candidate.id, lighting: "Morning",
                                     surface: "", notes: "", photoID: photo.id)
        }
        let reopened = try WorkspaceRepository(directory: directory)
        XCTAssertEqual(reopened.workspace.observations.first?.photoID, photo.id)
        try reopened.change { $0.removePhoto(id: photo.id) }
        XCTAssertNil(try WorkspaceRepository(directory: directory).workspace.observations.first?.photoID)
    }
}
