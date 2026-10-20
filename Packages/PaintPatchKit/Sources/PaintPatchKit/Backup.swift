import Foundation

public enum BackupError: Error, Equatable {
    case malformed
    case unsupportedFormat(Int)
    case checksumMismatch
    case missingPhoto
}

public struct BackupPhoto: Codable, Equatable, Sendable {
    public var id: UUID
    public var sha256: String
    public var byteCount: Int
    public var data: Data
}

/// Records without the photo inventory: app-local file names never leave the device.
struct BackupRecords: Codable, Equatable, Sendable {
    var rooms: [Room]
    var candidates: [Candidate]
    var observations: [PatchObservation]
    var selections: [Selection]
    var touchUps: [TouchUpEvent]
}

public struct BackupManifest: Codable, Equatable, Sendable {
    public var recordsSHA256: String
    public var roomCount: Int
    public var candidateCount: Int
    public var observationCount: Int
    public var selectionCount: Int
    public var touchUpCount: Int
    public var photoCount: Int
}

/// What a restore would do to the current notebook; computed without changing anything.
public struct BackupPreview: Equatable, Sendable {
    public struct Tally: Equatable, Sendable {
        public var new = 0
        public var duplicate = 0
    }
    public var createdAt: Date
    public var rooms = Tally()
    public var candidates = Tally()
    public var observations = Tally()
    public var selections = Tally()
    public var touchUps = Tally()
    public var photos = Tally()

    public var newRecordCount: Int {
        rooms.new + candidates.new + observations.new + selections.new + touchUps.new + photos.new
    }
}

/// Self-contained versioned JSON backup: records, photo bytes and checksums. No paths, no network.
public struct BackupDocument: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    public private(set) var formatVersion = BackupDocument.currentFormat
    public private(set) var createdAt: Date
    public private(set) var manifest: BackupManifest
    var records: BackupRecords
    public private(set) var photos: [BackupPhoto]

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func recordsHash(_ records: BackupRecords) throws -> String {
        SHA256.hex(try encoder().encode(records))
    }

    /// `photoData` supplies bytes per photo; a missing file fails the export instead of silently dropping it.
    public static func make(from workspace: PaintWorkspace, createdAt: Date = Date(),
                            photoData: (PhotoReference) throws -> Data?) throws -> BackupDocument {
        try workspace.validate()
        let records = BackupRecords(rooms: workspace.rooms, candidates: workspace.candidates,
                                    observations: workspace.observations, selections: workspace.selections,
                                    touchUps: workspace.touchUps)
        let photos = try workspace.photos.map { reference -> BackupPhoto in
            guard let data = try photoData(reference) else { throw BackupError.missingPhoto }
            return BackupPhoto(id: reference.id, sha256: SHA256.hex(data), byteCount: data.count, data: data)
        }
        let manifest = BackupManifest(recordsSHA256: try recordsHash(records),
                                      roomCount: records.rooms.count,
                                      candidateCount: records.candidates.count,
                                      observationCount: records.observations.count,
                                      selectionCount: records.selections.count,
                                      touchUpCount: records.touchUps.count, photoCount: photos.count)
        return BackupDocument(createdAt: createdAt, manifest: manifest, records: records, photos: photos)
    }

    public func encoded() throws -> Data { try Self.encoder().encode(self) }

    /// Parse and fully verify untrusted bytes: version, counts, checksums, unique ids and references.
    public static func decode(_ bytes: Data) throws -> BackupDocument {
        let document: BackupDocument
        do { document = try JSONDecoder().decode(BackupDocument.self, from: bytes) } catch { throw BackupError.malformed }
        guard document.formatVersion == currentFormat else {
            throw BackupError.unsupportedFormat(document.formatVersion)
        }
        let m = document.manifest, r = document.records
        guard m.roomCount == r.rooms.count, m.candidateCount == r.candidates.count,
              m.observationCount == r.observations.count, m.selectionCount == r.selections.count,
              m.touchUpCount == r.touchUps.count, m.photoCount == document.photos.count,
              m.recordsSHA256 == (try recordsHash(r)),
              document.photos.allSatisfy({ $0.byteCount == $0.data.count && $0.sha256 == SHA256.hex($0.data) })
        else { throw BackupError.checksumMismatch }
        // Standalone validity: ids unique and every reference resolves inside the backup itself.
        _ = try document.standaloneWorkspace()
        return document
    }

    private func standaloneWorkspace() throws -> PaintWorkspace {
        var workspace = PaintWorkspace()
        workspace.rooms = records.rooms
        workspace.candidates = records.candidates
        workspace.observations = records.observations
        workspace.selections = records.selections
        workspace.touchUps = records.touchUps
        workspace.photos = photos.map { PhotoReference(id: $0.id, fileName: $0.id.uuidString + ".jpg") }
        try workspace.validate()
        return workspace
    }

    public func preview(against workspace: PaintWorkspace) -> BackupPreview {
        func tally<T>(_ incoming: [T], _ existing: [T], id: KeyPath<T, UUID>) -> BackupPreview.Tally {
            let known = Set(existing.map { $0[keyPath: id] })
            let duplicates = incoming.filter { known.contains($0[keyPath: id]) }.count
            return .init(new: incoming.count - duplicates, duplicate: duplicates)
        }
        var preview = BackupPreview(createdAt: createdAt)
        preview.rooms = tally(records.rooms, workspace.rooms, id: \.id)
        preview.candidates = tally(records.candidates, workspace.candidates, id: \.id)
        preview.observations = tally(records.observations, workspace.observations, id: \.id)
        preview.selections = tally(records.selections, workspace.selections, id: \.id)
        preview.touchUps = tally(records.touchUps, workspace.touchUps, id: \.id)
        let knownPhotos = Set(workspace.photos.map(\.id))
        let duplicatePhotos = photos.filter { knownPhotos.contains($0.id) }.count
        preview.photos = .init(new: photos.count - duplicatePhotos, duplicate: duplicatePhotos)
        return preview
    }
}

extension PaintWorkspace {
    /// Merge: records whose id already exists are kept as-is (existing wins); new ids are appended.
    /// Result is validated, so a backup that would break references throws and changes nothing.
    func applying(_ backup: BackupDocument, photoFileNames: [UUID: String]) throws -> PaintWorkspace {
        var merged = self
        func add<T>(_ incoming: [T], to existing: inout [T], id: KeyPath<T, UUID>) {
            let known = Set(existing.map { $0[keyPath: id] })
            existing.append(contentsOf: incoming.filter { !known.contains($0[keyPath: id]) })
        }
        add(backup.records.rooms, to: &merged.rooms, id: \.id)
        add(backup.records.candidates, to: &merged.candidates, id: \.id)
        add(backup.records.observations, to: &merged.observations, id: \.id)
        add(backup.records.selections, to: &merged.selections, id: \.id)
        add(backup.records.touchUps, to: &merged.touchUps, id: \.id)
        for photo in backup.photos where !photos.contains(where: { $0.id == photo.id }) {
            guard let name = photoFileNames[photo.id] else { throw BackupError.malformed }
            try merged.addPhoto(PhotoReference(id: photo.id, fileName: name))
        }
        try merged.validate()
        return merged
    }
}

extension WorkspaceRepository {
    public func makeBackup(createdAt: Date = Date()) throws -> BackupDocument {
        try BackupDocument.make(from: workspace, createdAt: createdAt) { reference in
            try? Data(contentsOf: photoURL(reference))
        }
    }

    /// Writes new photos under app-generated names, then saves the merged workspace atomically.
    /// Any failure removes the photo files written by this call and leaves memory and disk unchanged.
    @discardableResult
    public func restore(_ backup: BackupDocument) throws -> BackupPreview {
        // Codable's public decoder can bypass `decode`; validate again at the write boundary.
        let backup = try BackupDocument.decode(backup.encoded())
        let preview = backup.preview(against: workspace)
        let known = Set(workspace.photos.map(\.id))
        let folder = directory.appendingPathComponent("photos", isDirectory: true)
        var written: [URL] = []
        var names: [UUID: String] = [:]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for photo in backup.photos where !known.contains(photo.id) {
                let name = UUID().uuidString + ".jpg"
                let url = folder.appendingPathComponent(name)
                try photo.data.write(to: url, options: .atomic)
                written.append(url)
                names[photo.id] = name
            }
            try change { (current: inout PaintWorkspace) -> Void in
                current = try current.applying(backup, photoFileNames: names)
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return preview
    }
}
