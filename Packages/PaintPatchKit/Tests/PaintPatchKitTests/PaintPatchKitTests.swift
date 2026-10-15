import XCTest
@testable import PaintPatchKit

final class PaintPatchKitTests: XCTestCase {
    private func fixture() -> (Room, Candidate, Candidate) {
        let room = Room(name: "Bedroom")
        let a = Candidate(roomID: room.id, label: "Sample A", brand: "Behr",
                          code: "PPU18-15", finish: "Eggshell")
        let b = Candidate(roomID: room.id, label: "Sample B", brand: "Behr",
                          code: "PPU18-15", finish: "Eggshell")
        return (room, a, b)
    }

    // MARK: unknown-safe comparison

    func testIdenticalTranscribedFactsMatch() {
        let (_, a, b) = fixture()
        XCTAssertTrue(PaintWorkspace.sameTranscribedPaint(a, b))
    }

    func testCaseAndWhitespaceInsensitiveButOnlyForCompleteFacts() {
        let (_, a, _) = fixture()
        let b = Candidate(roomID: a.roomID, label: "B", brand: " behr ",
                          code: "ppu18-15", finish: " eggshell ")
        XCTAssertTrue(PaintWorkspace.sameTranscribedPaint(a, b))
    }

    func testMissingCodeIsNeverAMatch() {
        let (_, a, _) = fixture()
        let b = Candidate(roomID: a.roomID, label: "B", brand: "Behr",
                          code: nil, finish: "Eggshell")
        XCTAssertFalse(PaintWorkspace.sameTranscribedPaint(a, b))
        XCTAssertFalse(PaintWorkspace.sameTranscribedPaint(b, a))
        let c = Candidate(roomID: a.roomID, label: "C") // fully unknown
        XCTAssertFalse(PaintWorkspace.sameTranscribedPaint(c, c))
    }

    func testBlankCodeIsNeverAMatch() {
        let (_, a, _) = fixture()
        let b = Candidate(roomID: a.roomID, label: "B", brand: "Behr",
                          code: "   ", finish: "Eggshell")
        XCTAssertFalse(PaintWorkspace.sameTranscribedPaint(a, b))
    }

    func testConflictingFinishIsNotAMatch() {
        let (_, a, _) = fixture()
        let b = Candidate(roomID: a.roomID, label: "B", brand: "Behr",
                          code: "PPU18-15", finish: "Semi-Gloss")
        XCTAssertFalse(PaintWorkspace.sameTranscribedPaint(a, b))
    }

    // MARK: selection history

    func testAppendOnlySelectionReversibleAndChronological() {
        let (room, a, b) = fixture()
        var ws = PaintWorkspace()
        ws.rooms = [room]; ws.candidates = [a, b]
        let t0 = Date(timeIntervalSince1970: 1_000)
        ws.selections = [
            Selection(roomID: room.id, candidateID: a.id, selectedAt: t0),
            Selection(roomID: room.id, candidateID: b.id, selectedAt: t0.addingTimeInterval(60)),
        ]
        XCTAssertEqual(ws.selectedCandidateID(in: room.id), b.id)
        // Undo = append a nil selection; history preserved.
        ws.selections.append(Selection(roomID: room.id, candidateID: nil,
                                       selectedAt: t0.addingTimeInterval(120)))
        XCTAssertNil(ws.selectedCandidateID(in: room.id))
        XCTAssertEqual(ws.selections.count, 3)
        XCTAssertNil(ws.selectedCandidateID(in: UUID()))
    }

    // MARK: photo references

    func testPhotoDeleteClearsObservationLinksAndRelinkValidates() throws {
        let (room, a, _) = fixture()
        var ws = PaintWorkspace()
        ws.rooms = [room]; ws.candidates = [a]
        let photo = PhotoReference(fileName: "patch-1.jpg")
        let other = PhotoReference(fileName: "patch-2.jpg")
        try ws.addPhoto(photo)
        try ws.addPhoto(other)
        let obs = PatchObservation(candidateID: a.id, lighting: "North window", photoID: photo.id)
        ws.observations = [obs]

        try ws.relinkPhoto(observationID: obs.id, to: other.id)
        XCTAssertEqual(ws.observations[0].photoID, other.id)
        try ws.relinkPhoto(observationID: obs.id, to: nil)
        XCTAssertNil(ws.observations[0].photoID)
        do {
            try ws.relinkPhoto(observationID: obs.id, to: UUID())
            XCTFail("unknown photo id must be rejected")
        } catch { XCTAssertEqual(error as? WorkspaceError, .invalidReference) }

        try ws.relinkPhoto(observationID: obs.id, to: photo.id)
        ws.removePhoto(id: photo.id)
        XCTAssertNil(ws.observations[0].photoID)
        XCTAssertNoThrow(try ws.validate())
        // Deleting the file then removing the last reference stays valid.
        ws.removePhoto(id: other.id)
        XCTAssertNoThrow(try ws.validate())
    }

    func testUnsafePhotoFileNameRejected() {
        var ws = PaintWorkspace()
        for bad in ["", "..", "a/b.jpg", "a\\b.jpg", "x\0y"] {
            XCTAssertThrowsError(try ws.addPhoto(PhotoReference(fileName: bad))) { error in
                XCTAssertEqual(error as? WorkspaceError, .invalidPhotoFileName)
            }
        }
        XCTAssertEqual(ws.photos.count, 0)
        XCTAssertNoThrow(try ws.addPhoto(PhotoReference(fileName: "safe.jpg")))
        XCTAssertThrowsError(try ws.addPhoto(PhotoReference(fileName: "safe.jpg")))
    }

    func testDanglingReferencesRejectedOnValidation() {
        let (room, a, _) = fixture()
        var ws = PaintWorkspace()
        ws.rooms = [room]
        ws.candidates = [Candidate(roomID: UUID(), label: "orphan")]
        XCTAssertThrowsError(try ws.validate())
        ws.candidates = [a]
        ws.observations = [PatchObservation(candidateID: a.id, photoID: UUID())]
        XCTAssertThrowsError(try ws.validate())
        ws.observations = []
        ws.selections = [Selection(roomID: room.id, candidateID: a.id)] // a lives in room: ok
        XCTAssertNoThrow(try ws.validate())
        ws.selections = [Selection(roomID: UUID(), candidateID: a.id)]
        XCTAssertThrowsError(try ws.validate())
    }

    // MARK: persistence and migration

    func testRoundTripAndRoundTripRejections() throws {
        let (room, a, b) = fixture()
        var ws = PaintWorkspace()
        ws.rooms = [room]; ws.candidates = [a, b]
        let photo = PhotoReference(fileName: "p.jpg")
        try ws.addPhoto(photo)
        ws.observations = [PatchObservation(candidateID: a.id, lighting: "Dusk", photoID: photo.id)]
        ws.selections = [Selection(roomID: room.id, candidateID: a.id)]
        ws.touchUps = [TouchUpEvent(candidateID: a.id, canLot: "LOT-9")]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paintpatch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try WorkspaceFile.save(ws, to: url)
        let loaded = try WorkspaceFile.load(from: url)
        XCTAssertEqual(loaded, ws)

        var dangling = ws
        dangling.touchUps = [TouchUpEvent(candidateID: UUID())]
        XCTAssertThrowsError(try WorkspaceFile.save(dangling, to: url))

        var duplicate = ws
        duplicate.rooms.append(room)
        XCTAssertThrowsError(try WorkspaceFile.save(duplicate, to: url))
    }

    func testV1FileMigratesToCurrentVersion() throws {
        let (room, a, _) = fixture()
        let v1 = """
        {"version":1,"rooms":[\(json(room))],"candidates":[\(json(a))],\
        "observations":[\(json(PatchObservation(candidateID: a.id, lighting: "Dusk")))],\
        "touchUps":[\(json(TouchUpEvent(candidateID: a.id)))]}
        """
        let ws = try JSONDecoder().decode(PaintWorkspace.self, from: Data(v1.utf8))
        XCTAssertEqual(ws.version, PaintWorkspace.currentVersion)
        XCTAssertEqual(ws.rooms.count, 1)
        XCTAssertEqual(ws.observations.count, 1)
        XCTAssertTrue(ws.photos.isEmpty)
        XCTAssertTrue(ws.selections.isEmpty)

        var unsupported = v1
        unsupported = unsupported.replacingOccurrences(of: "\"version\":1", with: "\"version\":3")
        XCTAssertThrowsError(try JSONDecoder().decode(PaintWorkspace.self, from: Data(unsupported.utf8))) { error in
            XCTAssertEqual(error as? WorkspaceError, .unsupportedVersion(3))
        }
        let tooOld = v1.replacingOccurrences(of: "\"version\":1", with: "\"version\":0")
        XCTAssertThrowsError(try JSONDecoder().decode(PaintWorkspace.self, from: Data(tooOld.utf8))) { error in
            XCTAssertEqual(error as? WorkspaceError, .unsupportedVersion(0))
        }
    }

    func testDecodedFileWithDanglingReferenceRejected() {
        let (room, a, _) = fixture()
        let bad = """
        {"version":2,"rooms":[\(json(room))],"candidates":[\(json(a))],\
        "photos":[],"observations":[\(json(PatchObservation(candidateID: a.id, photoID: UUID())))],\
        "selections":[],"touchUps":[]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(PaintWorkspace.self, from: Data(bad.utf8))) { error in
            XCTAssertEqual(error as? WorkspaceError, .invalidReference)
        }
    }

    private func json<T: Encodable>(_ value: T) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }
}
