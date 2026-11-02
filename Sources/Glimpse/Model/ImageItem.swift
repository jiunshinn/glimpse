import Foundation
import UniformTypeIdentifiers

struct ImageItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let fileSize: Int64
    let modified: Date
    let created: Date
    let kind: ItemKind

    var id: URL { url }
    var isVideo: Bool { kind == .video }
    var isDocument: Bool { kind == .document }
}

enum ItemKind: String, Codable, Sendable {
    case image
    case video
    /// A PDF, Word, Excel, PowerPoint or iWork file.
    case document
}

enum SortKey: Int, CaseIterable, Sendable {
    case name
    case dateModified
    case dateCreated
    case size

    var title: String {
        switch self {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .size: "Size"
        }
    }
}

/// Where the images of a window come from.
enum ImageSource: Equatable, Sendable {
    /// Every image in a folder.
    case folder(URL)
    /// A fixed set of files (for example, several files selected in Finder).
    case files([URL])
    /// The starred files, or the files with a tag, from all workspace folders.
    case smart(SmartList)
}

enum OpenRequest: Equatable {
    case folder(URL, selecting: URL?)
    case files([URL])
    case smart(SmartList)

    /// Turns the URLs from Finder, the Dock, the open panel or a drop into open requests.
    /// One file opens its whole folder. Several files open only those files.
    static func make(from urls: [URL]) -> [OpenRequest] {
        var folders: [URL] = []
        var files: [URL] = []
        for raw in urls {
            let url = raw.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
                if !isPackage { folders.append(url) }
            } else if FolderScanner.canOpen(url) {
                files.append(url)
            }
        }
        var requests = folders.map { OpenRequest.folder($0, selecting: nil) }
        if files.count == 1 {
            requests.append(.folder(files[0].deletingLastPathComponent(), selecting: files[0]))
        } else if files.count > 1 {
            requests.append(.files(files))
        }
        return requests
    }
}

enum FolderScanner {
    private static let resourceKeys: [URLResourceKey] = [
        .contentTypeKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
    ]

    /// Returns the sorted images, videos and documents of the source, or nil if the folder cannot be read.
    /// The files with a path in `pinned` come first.
    static func scan(_ source: ImageSource, sortedBy key: SortKey, ascending: Bool,
                     pinned: Set<String> = []) -> [ImageItem]? {
        let items: [ImageItem]
        switch source {
        case .folder(let folder):
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            ) else { return nil }
            items = urls.compactMap(item(for:))
        case .files(let urls):
            items = urls.compactMap(item(for:))
        case .smart:
            // The viewer model turns a smart list into files before it scans.
            items = []
        }
        return sorted(items, by: key, ascending: ascending, pinned: pinned)
    }

    static func item(for url: URL) -> ImageItem? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
              values.isRegularFile == true,
              let type = values.contentType,
              isSupported(type)
        else { return nil }
        return ImageItem(
            url: url.standardizedFileURL,
            name: url.lastPathComponent,
            fileSize: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? .distantPast,
            created: values.creationDate ?? .distantPast,
            kind: kind(of: type)
        )
    }

    static func canOpen(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return isSupported(type)
    }

    static func isSupported(_ type: UTType) -> Bool {
        type.conforms(to: .image) || VideoDecoder.isPlayable(type) || DocumentDecoder.isDocument(type)
    }

    private static func kind(of type: UTType) -> ItemKind {
        if type.conforms(to: .image) { return .image }
        return DocumentDecoder.isDocument(type) ? .document : .video
    }

    /// Sorts the files. The pinned files come first, in the same order among themselves.
    static func sorted(_ items: [ImageItem], by key: SortKey, ascending: Bool, pinned: Set<String> = []) -> [ImageItem] {
        let sorted = sortedByKey(items, key, ascending: ascending)
        guard !pinned.isEmpty else { return sorted }
        let isPinned = { (item: ImageItem) in pinned.contains(item.url.path) }
        return sorted.filter(isPinned) + sorted.filter { !isPinned($0) }
    }

    private static func sortedByKey(_ items: [ImageItem], _ key: SortKey, ascending: Bool) -> [ImageItem] {
        items.sorted { a, b in
            let order: ComparisonResult
            switch key {
            case .name:
                order = a.name.localizedStandardCompare(b.name)
            case .dateModified:
                order = compare(a.modified, b.modified, a, b)
            case .dateCreated:
                order = compare(a.created, b.created, a, b)
            case .size:
                order = compare(a.fileSize, b.fileSize, a, b)
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ x: T, _ y: T, _ a: ImageItem, _ b: ImageItem) -> ComparisonResult {
        if x < y { return .orderedAscending }
        if x > y { return .orderedDescending }
        return a.name.localizedStandardCompare(b.name)
    }
}

extension URL {
    /// Compares file paths with Unicode canonical equivalence, so NFC and NFD file names match.
    func isSameFile(as other: URL) -> Bool {
        path == other.path
    }
}
