import Foundation

/// A free canvas with files from different folders and notes. A board keeps references to the files, not copies.
struct Board: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var items: [BoardItem] = []
}

struct BoardItem: Identifiable, Codable, Hashable {
    var id = UUID()
    /// The path of the file. Nil for a note.
    var path: String?
    /// The text of a note. Nil for a file.
    var note: String?
    /// The top-left corner on the board, in points.
    var x: Double
    var y: Double
    var width: Double
    /// Width divided by height. Glimpse records it when the preview of the file loads.
    var aspect: Double?

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }
    var isNote: Bool { note != nil }

    /// The height on the board. A note gets an estimate, because its text sets its height.
    var height: Double { isNote ? 130 : width / max(aspect ?? 4.0 / 3.0, 0.05) }
}
