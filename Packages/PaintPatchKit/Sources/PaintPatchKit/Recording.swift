import Foundation

/// Blank transcriptions are unknown; never an inferred color fact.
public func paintFact(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

extension PaintWorkspace {
    @discardableResult
    public mutating func recordRoom(_ name: String) throws -> Room {
        guard let name = paintFact(name) else { throw WorkspaceError.invalidReference }
        let room = Room(name: name)
        rooms.append(room)
        return room
    }

    @discardableResult
    public mutating func recordCandidate(roomID: UUID, label: String, brand: String,
                                         code: String, finish: String, wallLocation: String,
                                         canLot: String) throws -> Candidate {
        guard rooms.contains(where: { $0.id == roomID }), let label = paintFact(label) else {
            throw WorkspaceError.invalidReference
        }
        let candidate = Candidate(roomID: roomID, label: label, brand: paintFact(brand),
                                  code: paintFact(code), finish: paintFact(finish),
                                  wallLocation: paintFact(wallLocation), canLot: paintFact(canLot))
        candidates.append(candidate)
        return candidate
    }

    @discardableResult
    public mutating func recordObservation(candidateID: UUID, lighting: String,
                                           surface: String, notes: String,
                                           photoID: UUID? = nil, observedAt: Date = Date()) throws -> Observation {
        guard candidates.contains(where: { $0.id == candidateID }),
              photoID == nil || photos.contains(where: { $0.id == photoID }) else {
            throw WorkspaceError.invalidReference
        }
        let observation = Observation(candidateID: candidateID, observedAt: observedAt,
                                      lighting: paintFact(lighting), surface: paintFact(surface),
                                      notes: paintFact(notes), photoID: photoID)
        observations.append(observation)
        return observation
    }
}

/// Copy-on-write persistence: failed validation/write never publishes an in-memory change.
public final class WorkspaceRepository {
    public private(set) var workspace: PaintWorkspace
    public let directory: URL
    private let fileURL: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        fileURL = directory.appendingPathComponent("workspace.json")
        workspace = FileManager.default.fileExists(atPath: fileURL.path)
            ? try WorkspaceFile.load(from: fileURL) : PaintWorkspace()
    }

    @discardableResult
    public func change<T>(_ edit: (inout PaintWorkspace) throws -> T) throws -> T {
        var copy = workspace
        let result = try edit(&copy)
        try WorkspaceFile.save(copy, to: fileURL)
        workspace = copy
        return result
    }

    /// Image bytes come only from explicit user picker selection. File name is app-generated.
    /// Failed registration removes the new file; never orphan it or publish an unsaved reference.
    public func addPhoto(_ data: Data) throws -> PhotoReference {
        let folder = directory.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = PhotoReference(fileName: UUID().uuidString + ".jpg")
        let url = folder.appendingPathComponent(photo.fileName)
        try data.write(to: url, options: .atomic)
        do {
            try change { try $0.addPhoto(photo) }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return photo
    }

    public func photoURL(_ photo: PhotoReference) -> URL {
        directory.appendingPathComponent("photos", isDirectory: true)
            .appendingPathComponent(photo.fileName)
    }
}
