import Foundation

public struct Room: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

/// Every paint fact is optional and user-transcribed. nil means unknown, never "close enough".
public struct Candidate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var roomID: UUID
    public var label: String
    public var brand: String?
    public var code: String?
    public var finish: String?
    public var wallLocation: String?
    public var canLot: String?

    public init(id: UUID = UUID(), roomID: UUID, label: String, brand: String? = nil,
                code: String? = nil, finish: String? = nil, wallLocation: String? = nil,
                canLot: String? = nil) {
        self.id = id; self.roomID = roomID; self.label = label; self.brand = brand
        self.code = code; self.finish = finish; self.wallLocation = wallLocation; self.canLot = canLot
    }
}

/// File name of an app-owned local photo copy; never a URL and never a color measurement.
public struct PhotoReference: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var fileName: String
    public init(id: UUID = UUID(), fileName: String) {
        self.id = id; self.fileName = fileName
    }
}

public struct Observation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var candidateID: UUID
    public var observedAt: Date
    public var lighting: String?
    public var surface: String?
    public var notes: String?
    public var photoID: UUID?

    public init(id: UUID = UUID(), candidateID: UUID, observedAt: Date = Date(),
                lighting: String? = nil, surface: String? = nil, notes: String? = nil,
                photoID: UUID? = nil) {
        self.id = id; self.candidateID = candidateID; self.observedAt = observedAt
        self.lighting = lighting; self.surface = surface; self.notes = notes; self.photoID = photoID
    }
}

/// Append-only: reverse a choice by appending a selection with `candidateID == nil`.
public struct Selection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var roomID: UUID
    public var candidateID: UUID?
    public var selectedAt: Date
    public init(id: UUID = UUID(), roomID: UUID, candidateID: UUID?, selectedAt: Date = Date()) {
        self.id = id; self.roomID = roomID; self.candidateID = candidateID; self.selectedAt = selectedAt
    }
}

public struct TouchUpEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var candidateID: UUID
    public var appliedAt: Date
    public var canLot: String?
    public var notes: String?
    public init(id: UUID = UUID(), candidateID: UUID, appliedAt: Date = Date(),
                canLot: String? = nil, notes: String? = nil) {
        self.id = id; self.candidateID = candidateID; self.appliedAt = appliedAt
        self.canLot = canLot; self.notes = notes
    }
}

public enum WorkspaceError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidReference
    case invalidPhotoFileName
}

/// Versioned local record set. v1 (no photo inventory, no selection history) migrates to v2 on decode.
public struct PaintWorkspace: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public private(set) var version = PaintWorkspace.currentVersion
    public var rooms: [Room] = []
    public var candidates: [Candidate] = []
    public var photos: [PhotoReference] = []
    public var observations: [Observation] = []
    public var selections: [Selection] = []
    public var touchUps: [TouchUpEvent] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, rooms, candidates, photos, observations, selections, touchUps
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard (1...PaintWorkspace.currentVersion).contains(storedVersion) else {
            throw WorkspaceError.unsupportedVersion(storedVersion)
        }
        rooms = try values.decode([Room].self, forKey: .rooms)
        candidates = try values.decode([Candidate].self, forKey: .candidates)
        observations = try values.decode([Observation].self, forKey: .observations)
        touchUps = try values.decode([TouchUpEvent].self, forKey: .touchUps)
        if storedVersion >= 2 {
            photos = try values.decode([PhotoReference].self, forKey: .photos)
            selections = try values.decode([Selection].self, forKey: .selections)
        }
        try validate()
    }

    public mutating func addPhoto(_ photo: PhotoReference) throws {
        guard PaintWorkspace.isSafeFileName(photo.fileName),
              !photos.contains(where: { $0.id == photo.id || $0.fileName == photo.fileName }) else {
            throw WorkspaceError.invalidPhotoFileName
        }
        photos.append(photo)
    }

    public mutating func relinkPhoto(observationID: UUID, to photoID: UUID?) throws {
        guard let index = observations.firstIndex(where: { $0.id == observationID }),
              photoID == nil || photos.contains(where: { $0.id == photoID }) else {
            throw WorkspaceError.invalidReference
        }
        observations[index].photoID = photoID
    }

    /// Clears observation links so none dangle. Caller deletes the file after saving.
    public mutating func removePhoto(id: UUID) {
        photos.removeAll { $0.id == id }
        for index in observations.indices where observations[index].photoID == id {
            observations[index].photoID = nil
        }
    }

    public func validate() throws {
        let roomIDs = Set(rooms.map(\.id))
        let candidateIDs = Set(candidates.map(\.id))
        let photoIDs = Set(photos.map(\.id))
        guard roomIDs.count == rooms.count, candidateIDs.count == candidates.count,
              photoIDs.count == photos.count,
              Set(photos.map(\.fileName)).count == photos.count,
              Set(observations.map(\.id)).count == observations.count,
              Set(selections.map(\.id)).count == selections.count,
              Set(touchUps.map(\.id)).count == touchUps.count,
              photos.allSatisfy({ PaintWorkspace.isSafeFileName($0.fileName) }) else {
            throw WorkspaceError.invalidReference
        }
        for candidate in candidates where !roomIDs.contains(candidate.roomID) {
            throw WorkspaceError.invalidReference
        }
        for observation in observations {
            guard candidateIDs.contains(observation.candidateID) else { throw WorkspaceError.invalidReference }
            if let photoID = observation.photoID, !photoIDs.contains(photoID) {
                throw WorkspaceError.invalidReference
            }
        }
        for touchUp in touchUps where !candidateIDs.contains(touchUp.candidateID) {
            throw WorkspaceError.invalidReference
        }
        for selection in selections {
            guard roomIDs.contains(selection.roomID) else { throw WorkspaceError.invalidReference }
            if let chosen = selection.candidateID {
                guard let candidate = candidates.first(where: { $0.id == chosen }),
                      candidate.roomID == selection.roomID else { throw WorkspaceError.invalidReference }
            }
        }
    }

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") &&
            !name.contains("\\") && !name.contains("\0")
    }

    /// Currently selected candidate per room: latest selection event wins; nil means none or undone.
    public func selectedCandidateID(in roomID: UUID) -> UUID? {
        selections.enumerated()
            .filter { $0.element.roomID == roomID }
            .max { ($0.element.selectedAt, $0.offset) < ($1.element.selectedAt, $1.offset) }?
            .element.candidateID
    }

    /// True only when brand, code and finish are all present on both sides and equal as typed.
    /// Unknown on either side is never a match; no pixel-derived or fuzzy matching exists.
    public static func sameTranscribedPaint(_ left: Candidate, _ right: Candidate) -> Bool {
        func known(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed.lowercased()
        }
        guard let lb = known(left.brand), let rb = known(right.brand),
              let lc = known(left.code), let rc = known(right.code),
              let lf = known(left.finish), let rf = known(right.finish) else { return false }
        return lb == rb && lc == rc && lf == rf
    }
}

public enum WorkspaceFile {
    public static func load(from url: URL) throws -> PaintWorkspace {
        try JSONDecoder().decode(PaintWorkspace.self, from: Data(contentsOf: url))
    }

    public static func save(_ workspace: PaintWorkspace, to url: URL) throws {
        try workspace.validate()
        try JSONEncoder().encode(workspace).write(to: url, options: .atomic)
    }
}
