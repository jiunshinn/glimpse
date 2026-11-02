import Foundation

/// Shows only some kinds of files (images, videos or documents) or only some formats (for example HEIC and RAW).
struct TypeFilter: Equatable, Codable, Sendable {
    var kind: ItemKind?
    var formats: Set<String> = []

    init(kind: ItemKind? = nil, formats: Set<String> = []) {
        self.kind = kind
        self.formats = formats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(ItemKind.self, forKey: .kind)
        formats = try container.decodeIfPresent(Set<String>.self, forKey: .formats) ?? []
    }

    var isActive: Bool { kind != nil || !formats.isEmpty }

    func allows(_ item: ImageItem) -> Bool {
        (kind == nil || item.kind == kind) && (formats.isEmpty || formats.contains(item.format))
    }

    /// A short name, for example "Videos" or "HEIC, DNG".
    var title: String {
        if !formats.isEmpty { return formats.sorted().joined(separator: ", ") }
        return kind?.pluralTitle ?? "All Types"
    }
}

extension ItemKind {
    var pluralTitle: String {
        switch self {
        case .image: "Images"
        case .video: "Videos"
        case .document: "Documents"
        }
    }
}

extension ImageItem {
    /// The file format as an uppercase extension. JPEG and JPG are one format, and so are TIF and TIFF.
    var format: String {
        let name = url.pathExtension.uppercased()
        switch name {
        case "JPEG", "JPE": return "JPG"
        case "TIF": return "TIFF"
        case "": return "Other"
        default: return name
        }
    }
}
