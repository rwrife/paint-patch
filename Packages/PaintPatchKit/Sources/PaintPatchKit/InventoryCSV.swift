import Foundation

extension PaintWorkspace {
    /// Room/can inventory as RFC 4180 CSV. Unknown facts print "Unknown"; internal ids and
    /// photo paths are never emitted. Spreadsheet formula prefixes are neutralised with a leading apostrophe.
    public func inventoryCSV() throws -> String {
        try validate()
        var lines = [["Room", "Sample", "Brand", "Code", "Finish", "Patch location", "Can lot"]]
        for room in rooms {
            for candidate in candidates where candidate.roomID == room.id {
                lines.append([room.name, candidate.label, candidate.brand ?? "Unknown",
                              candidate.code ?? "Unknown", candidate.finish ?? "Unknown",
                              candidate.wallLocation ?? "Unknown", candidate.canLot ?? "Unknown"])
            }
        }
        return lines.map { $0.map(Self.csvField).joined(separator: ",") + "\r\n" }.joined()
    }

    static func csvField(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ")
        if let first = value.first(where: { $0 != " " }), "=+-@".contains(first) { value = "'" + value }
        guard value.contains(where: { ",\"\n".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
