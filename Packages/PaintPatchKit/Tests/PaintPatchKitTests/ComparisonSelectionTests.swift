import XCTest
@testable import PaintPatchKit

final class ComparisonSelectionTests: XCTestCase {
    private func fixture() -> (Room, Candidate, Candidate) {
        let room = Room(name: "Bedroom")
        let a = Candidate(roomID: room.id, label: "Sample A", brand: "Behr",
                          code: "PPU18-15", finish: "Eggshell")
        let b = Candidate(roomID: room.id, label: "Sample B")
        return (room, a, b)
    }

    func testTranscribedMatchRequiresExactTextAndUnknownStaysUnknown() {
        let (room, a, b) = fixture()
        XCTAssertFalse(PaintWorkspace.sameTranscribedPaint(a, b)) // b unknown → never a match
        let twin = Candidate(roomID: room.id, label: "Twin", brand: "BEHR",
                             code: " ppu18-15 ", finish: "Eggshell")
        XCTAssertTrue(PaintWorkspace.sameTranscribedPaint(a, twin))
        let rival = Candidate(roomID: room.id, label: "Rival", brand: "Behr",
                              code: "PPU18-15", finish: "Semi-Gloss")
        XCTAssertFalse(PaintWorkspace.sameTranscribedPaint(a, rival))
        XCTAssertFalse(PaintWorkspace.sameTranscribedPaint(b, b))
    }

    func testMixedLightingIsProvenanceNotAColorMatch() throws {
        let (room, a, _) = fixture()
        var ws = PaintWorkspace()
        ws.rooms = [room]
        ws.candidates = [a]
        let morning = try ws.recordObservation(candidateID: a.id, lighting: " North window ",
                                                surface: "wall", notes: "", observedAt: .distantPast)
        let evening = try ws.recordObservation(candidateID: a.id, lighting: " Warm lamp ",
                                                surface: "wall", notes: "", observedAt: .distantFuture)
        XCTAssertEqual(ws.observations.map(\.lighting), ["North window", "Warm lamp"])
        XCTAssertNotEqual(morning.lighting, evening.lighting)
        XCTAssertNil(ws.selectedCandidateID(in: room.id), "Observations cannot select paint")
        let unknownFinish = Candidate(roomID: room.id, label: "Same code", brand: a.brand,
                                      code: a.code, finish: nil)
        XCTAssertFalse(PaintWorkspace.sameTranscribedPaint(a, unknownFinish))
        let bytes = try JSONEncoder().encode(ws)
        XCTAssertEqual(try JSONDecoder().decode(PaintWorkspace.self, from: bytes), ws)
    }

    func testSelectionValidatesRoomMembershipAndAppendOnlyHistory() throws {
        let (room, a, b) = fixture()
        var ws = PaintWorkspace()
        ws.rooms = [room]; ws.candidates = [a, b]
        let t0 = Date(timeIntervalSince1970: 500)
        _ = try ws.selectCandidate(a.id, in: room.id, selectedAt: t0)
        XCTAssertThrowsError(try ws.selectCandidate(b.id, in: UUID()))
        let rivalRoom = Room(name: "Hall")
        ws.rooms.append(rivalRoom)
        XCTAssertThrowsError(try ws.selectCandidate(a.id, in: rivalRoom.id))

        _ = try ws.selectCandidate(b.id, in: room.id, selectedAt: t0.addingTimeInterval(60))
        XCTAssertEqual(ws.selectedCandidateID(in: room.id), b.id)
        _ = try ws.deselect(in: room.id, selectedAt: t0.addingTimeInterval(120))
        XCTAssertNil(ws.selectedCandidateID(in: room.id))
        // Selections and revisions remain in history.
        XCTAssertEqual(ws.selections.count, 3)
        XCTAssertThrowsError(try ws.deselect(in: UUID()))
    }

    func testTouchUpLogUnknownLotStaysUnknownAndOrdersOldestFirst() throws {
        let (room, a, b) = fixture()
        var ws = PaintWorkspace()
        ws.rooms = [room]; ws.candidates = [a, b]
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first = try ws.logTouchUp(candidateID: a.id, canLot: " LOT-9 ", notes: "  ",
                                      appliedAt: t0)
        XCTAssertEqual(first.canLot, "LOT-9")
        XCTAssertNil(first.notes)
        _ = try ws.logTouchUp(candidateID: a.id, canLot: "   ", notes: "Second",
                              appliedAt: t0.addingTimeInterval(60))
        XCTAssertEqual(ws.touchUps(for: a.id).map(\.canLot), ["LOT-9", nil])
        XCTAssertEqual(ws.touchUps(for: a.id).map(\.appliedAt), [t0, t0.addingTimeInterval(60)])
        XCTAssertTrue(ws.touchUps(for: b.id).isEmpty)
        XCTAssertThrowsError(try ws.logTouchUp(candidateID: UUID(), canLot: "", notes: ""))
        XCTAssertThrowsError(try ws.logTouchUp(in: room.id, canLot: "", notes: ""))
        _ = try ws.selectCandidate(a.id, in: room.id)
        let applied = try ws.logTouchUp(in: room.id, canLot: "", notes: "Final coat")
        XCTAssertEqual(applied.candidateID, a.id)
        XCTAssertEqual(ws.touchUps(in: room.id).count, 3)
        _ = try ws.deselect(in: room.id)
        XCTAssertThrowsError(try ws.logTouchUp(in: room.id, canLot: "", notes: ""))
    }

    func testSelectionAndTouchUpSurvivePersistenceAndValidation() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = try WorkspaceRepository(directory: directory)
        let room = try repository.change { try $0.recordRoom("Den") }
        let candidate = try repository.change {
            try $0.recordCandidate(roomID: room.id, label: "A", brand: "", code: "",
                                   finish: "", wallLocation: "", canLot: "")
        }
        _ = try repository.change { try $0.selectCandidate(candidate.id, in: room.id) }
        _ = try repository.change {
            try $0.logTouchUp(candidateID: candidate.id, canLot: "LOT-1", notes: "door trim")
        }
        let reopened = try WorkspaceRepository(directory: directory)
        XCTAssertEqual(reopened.workspace.selectedCandidateID(in: room.id), candidate.id)
        XCTAssertEqual(reopened.workspace.touchUps(for: candidate.id).count, 1)
        // A selection referencing another room's candidate must never load from disk.
        let forged = reopened.workspace
        var raw = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(forged)) as! [String: Any]
        raw["selections"] = [["id": UUID().uuidString, "roomID": UUID().uuidString,
                             "candidateID": candidate.id.uuidString,
                             "selectedAt": Date().timeIntervalSince1970]]
        let badURL = directory.appendingPathComponent("forged.json")
        try JSONSerialization.data(withJSONObject: raw).write(to: badURL)
        XCTAssertThrowsError(try WorkspaceFile.load(from: badURL))
    }
}
