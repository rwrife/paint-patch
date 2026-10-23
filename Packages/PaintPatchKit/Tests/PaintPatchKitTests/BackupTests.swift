import Foundation
import XCTest
@testable import PaintPatchKit

final class BackupTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(_ repository: WorkspaceRepository) throws -> (Room, Candidate, PhotoReference) {
        let room = try repository.change { try $0.recordRoom("Kitchen") }
        let candidate = try repository.change {
            try $0.recordCandidate(roomID: room.id, label: "Sample", brand: "", code: "",
                                   finish: "", wallLocation: "", canLot: "")
        }
        let photo = try repository.addPhoto(Data([0xff, 0xd8, 0xff, 0xd9]))
        try repository.change {
            _ = try $0.recordObservation(candidateID: candidate.id, lighting: "Daylight", surface: "wall",
                                         notes: "", photoID: photo.id)
            _ = try $0.selectCandidate(candidate.id, in: room.id)
            _ = try $0.logTouchUp(in: room.id, canLot: "", notes: "test")
        }
        return (room, candidate, photo)
    }

    func testKnownSHA256Vector() {
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testPreviewRoundTripWithPhotosAndDuplicateSkip() throws {
        let source = try WorkspaceRepository(directory: tempDirectory())
        let (room, candidate, photo) = try fixture(source)
        let date = Date(timeIntervalSince1970: 12345)
        let bytes = try source.makeBackup(createdAt: date).encoded()
        let backup = try BackupDocument.decode(bytes)
        XCTAssertEqual(backup.createdAt, date)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(source.directory.path))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(photo.fileName))
        let target = try WorkspaceRepository(directory: tempDirectory())
        let preview = backup.preview(against: target.workspace)
        XCTAssertEqual(preview.rooms.new, 1)
        XCTAssertEqual(preview.candidates.new, 1)
        XCTAssertEqual(preview.photos.new, 1)
        XCTAssertEqual(preview.newRecordCount, 6)
        XCTAssertTrue(preview.canApply)
        XCTAssertTrue(target.workspace.rooms.isEmpty, "Preview must not write")
        try target.restore(backup)
        XCTAssertEqual(target.workspace.rooms, [room])
        XCTAssertNil(target.workspace.candidates.first?.code)
        XCTAssertNil(target.workspace.candidates.first?.finish)
        XCTAssertEqual(target.workspace.selectedCandidateID(in: room.id), candidate.id)
        XCTAssertEqual(target.workspace.touchUps.count, 1)
        let newPhoto = try XCTUnwrap(target.workspace.photos.first)
        XCTAssertNotEqual(newPhoto.fileName, photo.fileName)
        XCTAssertEqual(try Data(contentsOf: target.photoURL(newPhoto)), Data([0xff, 0xd8, 0xff, 0xd9]))
        let again = try WorkspaceRepository(directory: target.directory)
        XCTAssertEqual(again.workspace, target.workspace)
        let duplicate = backup.preview(against: again.workspace)
        XCTAssertEqual(duplicate.newRecordCount, 0)
        XCTAssertEqual(duplicate.photos.duplicate, 1)
        _ = try again.restore(backup)
        XCTAssertEqual(again.workspace, target.workspace)
    }

    func testMalformedUnsupportedAndTamperedImportsDoNotMutate() throws {
        let source = try WorkspaceRepository(directory: tempDirectory())
        _ = try fixture(source)
        let good = try source.makeBackup().encoded()
        XCTAssertThrowsError(try BackupDocument.decode(Data("{bad".utf8)))
        func mutate(_ key: String, to value: Any) throws -> Data {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
            json[key] = value
            return try JSONSerialization.data(withJSONObject: json)
        }
        XCTAssertThrowsError(try BackupDocument.decode(try mutate("formatVersion", to: 42))) { error in
            XCTAssertEqual(error as? BackupError, .unsupportedFormat(42))
        }
        XCTAssertThrowsError(try BackupDocument.decode(try mutate("photos", to: []))) { error in
            XCTAssertEqual(error as? BackupError, .checksumMismatch)
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        var photos = try XCTUnwrap(json["photos"] as? [[String: Any]])
        photos[0]["data"] = Data([0]).base64EncodedString()
        json["photos"] = photos
        XCTAssertThrowsError(try BackupDocument.decode(try JSONSerialization.data(withJSONObject: json)))
        let target = try WorkspaceRepository(directory: tempDirectory())
        XCTAssertTrue(target.workspace.rooms.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.directory.path).isEmpty)
    }

    func testMissingPhotoExportFailsAndRestoreConflictRollsBack() throws {
        let source = try WorkspaceRepository(directory: tempDirectory())
        let (_, candidate, photo) = try fixture(source)
        let backup = try BackupDocument.decode(source.makeBackup().encoded())
        try FileManager.default.removeItem(at: source.photoURL(photo))
        XCTAssertThrowsError(try source.makeBackup()) { error in
            XCTAssertEqual(error as? BackupError, .missingPhoto)
        }
        let target = try WorkspaceRepository(directory: tempDirectory())
        // Same candidate id but a different room: incoming observation would refer to a duplicate id
        // already bound to another room. Reject the merge atomically, including staged photo bytes.
        let otherRoom = try target.change { try $0.recordRoom("Other") }
        try target.change {
            $0.candidates.append(Candidate(id: candidate.id, roomID: otherRoom.id, label: "Other paint"))
        }
        let before = target.workspace
        let preview = backup.preview(against: before)
        XCTAssertFalse(preview.canApply, "Conflicting room membership must be shown before Apply")
        XCTAssertEqual(target.workspace, before, "Preview must leave notebook untouched")
        let folder = target.directory.appendingPathComponent("photos")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Preview must not stage photos")
        XCTAssertThrowsError(try target.restore(backup))
        XCTAssertEqual(target.workspace, before)
        XCTAssertEqual(try WorkspaceRepository(directory: target.directory).workspace, before)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

}
