import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// A Mac folder that paired phones can browse.
struct SharedFolder: Codable, Identifiable, Equatable {
    /// Short and stable, so a phone can keep its place across launches.
    var id: String
    var path: String
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { FileManager.default.displayName(atPath: path) }
}

/// The folders the user shares with paired phones (**Share with Phone** in the sidebar).
/// A phone sees only these folders and the folders inside them, never the rest of the disk.
@MainActor
@Observable
final class SharedFolders {
    static let shared = SharedFolders()

    private(set) var folders: [SharedFolder] = []
    @ObservationIgnored private let file: URL

    private init() {
        file = PeerService.shared.storageDirectory.appendingPathComponent("SharedFolders.json")
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode([SharedFolder].self, from: data) {
            folders = stored
        }
    }

    func isShared(_ url: URL) -> Bool {
        folders.contains { $0.path == url.standardizedFileURL.path }
    }

    func toggle(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let index = folders.firstIndex(where: { $0.path == path }) {
            folders.remove(at: index)
        } else {
            folders.append(SharedFolder(id: "s" + Data.random(count: 6).base64URLEncoded, path: path))
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(folders).write(to: file, options: .atomic)
    }
}

/// Answers a phone's requests for the shared folders. It runs off the main thread and reads only inside shared folders.
enum SharedLibrary {
    /// `GET /v1/albums`: the shared folders.
    static func albums(_ roots: [SharedFolder]) -> [[String: Any]] {
        roots.filter { FileManager.default.fileExists(atPath: $0.path) }.map { root in
            let count = FolderScanner.scan(.folder(root.url), sortedBy: .name, ascending: true)?.count ?? 0
            return ["id": root.id, "name": root.name, "count": count]
        }
    }

    /// `GET /v1/albums/{id}/items?path=`: the subfolders and the files Glimpse shows, newest first.
    static func items(in root: SharedFolder, path: String) -> [String: Any]? {
        guard let folder = resolve(root, path), (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { return nil }
        let manager = FileManager.default
        let children = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey],
                                                         options: [.skipsHiddenFiles])) ?? []
        var entries: [[String: Any]] = children.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey])
            guard values?.isDirectory == true, values?.isPackage != true else { return nil }
            let count = (try? manager.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") }.count ?? 0
            return ["id": "", "kind": "folder", "name": url.lastPathComponent, "path": relative(url, in: root),
                    "count": count, "modified": values?.contentModificationDate?.timeIntervalSince1970 ?? 0]
        }.sorted { ($0["name"] as! String).localizedStandardCompare($1["name"] as! String) == .orderedAscending }

        let files = FolderScanner.scan(.folder(folder), sortedBy: .dateModified, ascending: false) ?? []
        entries += files.map { item in
            let type = UTType(filenameExtension: item.url.pathExtension)
            return [
                "id": itemID(root, relative(item.url, in: root)),
                "kind": item.kind.rawValue,
                "name": item.name,
                "mime": type?.preferredMIMEType ?? "application/octet-stream",
                "size": item.fileSize,
                "modified": item.modified.timeIntervalSince1970,
            ]
        }
        return ["path": path, "items": entries]
    }

    /// The file of an item ID, if it is inside a shared folder.
    static func file(for itemID: String, roots: [SharedFolder]) -> URL? {
        guard itemID.hasPrefix("m"), let data = Data(base64URLEncoded: String(itemID.dropFirst())),
              let text = String(data: data, encoding: .utf8), let slash = text.firstIndex(of: "/"),
              let root = roots.first(where: { $0.id == String(text[..<slash]) }) else { return nil }
        guard let url = resolve(root, String(text[text.index(after: slash)...])),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return url
    }

    /// A JPEG preview: Glimpse's own decoders for photos, videos and documents.
    static func thumbnail(_ url: URL, size: Int) -> Data? {
        guard let thumbnail = ImageDecoder.decodeThumbnail(url, maxPixelSize: size) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail.image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: - Paths

    private static func itemID(_ root: SharedFolder, _ relative: String) -> String {
        "m" + Data("\(root.id)/\(relative)".utf8).base64URLEncoded
    }

    private static func relative(_ url: URL, in root: SharedFolder) -> String {
        let base = root.url.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == base ? "" : String(path.dropFirst(base.count + 1))
    }

    /// A path inside the shared folder, or nil when it leaves it (`..`, a symbolic link to elsewhere, a hidden name).
    private static func resolve(_ root: SharedFolder, _ relative: String) -> URL? {
        let parts = relative.split(separator: "/")
        guard !parts.contains(where: { $0 == ".." || $0.hasPrefix(".") }) else { return nil }
        let base = root.url.resolvingSymlinksInPath().standardizedFileURL
        let url = parts.reduce(base) { $0.appendingPathComponent(String($1)) }.resolvingSymlinksInPath().standardizedFileURL
        return url.path == base.path || url.path.hasPrefix(base.path + "/") ? url : nil
    }
}

extension Data {
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
