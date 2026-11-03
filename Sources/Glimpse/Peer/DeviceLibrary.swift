import Foundation
import Observation
import UniformTypeIdentifiers

/// A place on a paired phone that the sidebar can show.
enum DeviceLocation: Hashable {
    case album(device: String, id: String)
    /// A folder of the phone's shared storage. "" is the top folder.
    case folder(device: String, path: String)

    var deviceID: String {
        switch self {
        case .album(let device, _), .folder(let device, _): device
        }
    }
}

struct PhoneAlbum: Identifiable, Hashable {
    var id: String
    var name: String
    var count: Int
}

struct PhoneFolder: Identifiable, Hashable {
    var path: String
    var name: String
    var count: Int
    var id: String { path }
}

/// A paired phone, as the sidebar shows it.
struct Phone: Identifiable, Equatable {
    var id: String
    var name: String
    var fingerprint: String
    var host: String?
    var port: Int?
    var lastHello: Date?
}

/// The phones' albums and folders on this Mac.
///
/// Glimpse opens a phone album or folder as a local cache folder, so the viewer, the grid, boards and drag-out
/// work as for any folder. A photo arrives first as a small preview with its real name. When the viewer shows
/// it, the full file takes its place, and the folder watcher reloads it. Videos and documents arrive whole.
@MainActor
@Observable
final class DeviceLibrary {
    static let shared = DeviceLibrary()

    /// A phone that said hello in this time is online. Phones say hello every 30 seconds.
    static let onlineWindow: TimeInterval = 75
    static let previewSize = 640

    private(set) var phones: [Phone] = []
    private(set) var albums: [String: [PhoneAlbum]] = [:]
    /// Subfolders by "device/path".
    private(set) var folders: [String: [PhoneFolder]] = [:]
    /// A message for a phone ("device") or for its files ("device/files").
    private(set) var problems: [String: String] = [:]
    /// Locations that download now, with the count of files still to come.
    private(set) var pending: [DeviceLocation: Int] = [:]
    /// Changes every 15 seconds, so the online state of each phone updates.
    private(set) var clock = Date()

    let root: URL
    @ObservationIgnored private var clients: [String: PhoneClient] = [:]
    @ObservationIgnored private var syncs: [DeviceLocation: Task<Void, Never>] = [:]
    @ObservationIgnored private var remote: [String: RemoteFile] = [:]
    @ObservationIgnored private var fullDownloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshedAt: [String: Date] = [:]

    /// What a cache file stands for on the phone.
    private struct RemoteFile: Codable {
        var device: String
        var item: String
        var isFull: Bool
        var modified: Date
        var created: Date?
    }

    /// The folder of all phone caches.
    nonisolated static let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Glimpse/Devices", isDirectory: true)

    /// True for a file or folder in a phone cache. It works on any thread.
    nonisolated static func isCacheItem(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(cacheRoot.standardizedFileURL.path + "/")
    }

    private init() {
        root = Self.cacheRoot
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { DeviceLibrary.shared.clock = Date() }
        }
        reloadPhones()
    }

    func isOnline(_ phone: Phone) -> Bool {
        guard let seen = phone.lastHello else { return false }
        return clock.timeIntervalSince(seen) < Self.onlineWindow || Date().timeIntervalSince(seen) < Self.onlineWindow
    }

    /// Follows the paired devices of `PeerService`.
    func reloadPhones() {
        let paired = PeerService.shared.devices.filter { $0.platform == "android" }
        phones = paired.map { device in
            var phone = phones.first { $0.fingerprint == device.fingerprint }
                ?? Phone(id: device.id, name: device.name, fingerprint: device.fingerprint)
            phone.name = device.name
            return phone
        }
    }

    /// A phone told where its server listens.
    func hello(fingerprint: String, host: String, port: Int, name: String?) {
        reloadPhones()
        guard let index = phones.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        let wasOnline = isOnline(phones[index])
        let moved = phones[index].host != host || phones[index].port != port
        phones[index].host = host
        phones[index].port = port
        phones[index].lastHello = Date()
        clock = Date()
        if moved {
            clients[phones[index].id]?.invalidate()
            clients[phones[index].id] = nil
        }
        // Albums change when the user takes photos or allows more of them, so load them again now and then.
        let stale = refreshedAt[phones[index].id].map { Date().timeIntervalSince($0) > 60 } ?? true
        if !wasOnline || moved || stale {
            refresh(phones[index].id)
        }
    }

    // MARK: - Albums and folders

    func refresh(_ deviceID: String) {
        refreshedAt[deviceID] = Date()
        Task {
            guard let client = client(for: deviceID) else { return }
            do {
                let json = try await client.json("/v1/albums")
                let list = (json["albums"] as? [[String: Any]] ?? []).compactMap { album -> PhoneAlbum? in
                    guard let id = album["id"] as? String, let name = album["name"] as? String else { return nil }
                    return PhoneAlbum(id: id, name: name, count: album["count"] as? Int ?? 0)
                }
                albums[deviceID] = list
                problems[deviceID] = nil
            } catch let error as PhoneError {
                problems[deviceID] = error.message
            } catch {}
            loadFolders(deviceID, path: "")
        }
    }

    /// Loads the subfolders of a phone folder for the sidebar.
    func loadFolders(_ deviceID: String, path: String) {
        Task {
            guard let client = client(for: deviceID) else { return }
            do {
                let json = try await client.json("/v1/files", query: ["path": path])
                let items = json["items"] as? [[String: Any]] ?? []
                folders["\(deviceID)/\(path)"] = items.compactMap { item in
                    guard item["kind"] as? String == "folder", let path = item["path"] as? String,
                          let name = item["name"] as? String else { return nil }
                    return PhoneFolder(path: path, name: name, count: item["count"] as? Int ?? 0)
                }
                problems["\(deviceID)/files"] = nil
            } catch let error as PhoneError {
                problems["\(deviceID)/files"] = error.code == "files_not_allowed"
                    ? "On the phone, allow “Folders and files” in Glimpse." : error.message
            } catch {}
        }
    }

    func subfolders(_ deviceID: String, path: String) -> [PhoneFolder]? {
        folders["\(deviceID)/\(path)"]
    }

    // MARK: - Opening

    /// The cache folder of a location. Opening it starts the download of what is new on the phone.
    func open(_ location: DeviceLocation) -> URL {
        let folder = cacheFolder(for: location)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        syncs[location]?.cancel()
        syncs[location] = Task { await sync(location, into: folder) }
        return folder
    }

    /// The location of a cache folder, so the sidebar can select its row.
    func location(forCacheFolder url: URL) -> DeviceLocation? {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path + "/"
        guard path.hasPrefix(base) else { return nil }
        let parts = path.dropFirst(base.count).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let device = parts[0]
        switch parts[1] {
        case "Albums" where parts.count == 3:
            let album = albums[device]?.first { Self.folderName($0.name) == parts[2] }
            return album.map { .album(device: device, id: $0.id) }
        case "Files":
            return .folder(device: device, path: parts.dropFirst(2).joined(separator: "/"))
        default:
            return nil
        }
    }

    func isCache(_ url: URL) -> Bool {
        Self.isCacheItem(url)
    }

    func title(for location: DeviceLocation) -> String {
        switch location {
        case .album(let device, let id): albums[device]?.first { $0.id == id }?.name ?? "Album"
        case .folder(_, let path): path.isEmpty ? "Files" : (path as NSString).lastPathComponent
        }
    }

    private func cacheFolder(for location: DeviceLocation) -> URL {
        let device = root.appendingPathComponent(location.deviceID, isDirectory: true)
        switch location {
        case .album:
            return device.appendingPathComponent("Albums", isDirectory: true)
                .appendingPathComponent(Self.folderName(title(for: location)), isDirectory: true)
        case .folder(_, let path):
            return path.split(separator: "/").reduce(device.appendingPathComponent("Files", isDirectory: true)) {
                $0.appendingPathComponent(Self.folderName(String($1)), isDirectory: true)
            }
        }
    }

    private static func folderName(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return clean.isEmpty || clean.hasPrefix(".") ? "_" + clean : clean
    }

    // MARK: - Full files

    /// True if the file is still a small preview of a phone photo.
    func isPreview(_ url: URL) -> Bool {
        guard isCache(url) else { return false }
        let file = remote[url.standardizedFileURL.path] ?? loadManifestEntry(for: url)
        return file.map { !$0.isFull } ?? false
    }

    /// The viewer shows these files, or a drag carries them: replace their previews with the full files.
    func wantFull(_ urls: [URL]) {
        for url in urls where isCache(url) {
            let key = url.standardizedFileURL.path
            guard let file = remote[key] ?? loadManifestEntry(for: url), !file.isFull,
                  fullDownloads[key] == nil else { continue }
            fullDownloads[key] = Task {
                await downloadFull(file, to: url)
                fullDownloads[key] = nil
            }
        }
    }

    /// Returns when the full files are in place, or when their downloads failed.
    func ensureFull(_ urls: [URL]) async {
        wantFull(urls)
        let tasks = urls.compactMap { fullDownloads[$0.standardizedFileURL.path] }
        for task in tasks { await task.value }
    }

    private func downloadFull(_ file: RemoteFile, to url: URL) async {
        guard let client = client(for: file.device) else { return }
        do {
            let temporary = try await client.download("/v1/items/\(file.item)/content")
            try place(temporary, at: url, modified: file.modified, created: file.created)
            var full = file
            full.isFull = true
            remote[url.standardizedFileURL.path] = full
            saveManifest(in: url.deletingLastPathComponent())
        } catch {}
    }

    // MARK: - Sync

    private struct Entry {
        var item: String
        var name: String
        var kind: String
        var size: Int64
        var modified: Date
        var taken: Date?
    }

    private func sync(_ location: DeviceLocation, into folder: URL) async {
        guard let client = client(for: location.deviceID) else { return }
        loadManifest(in: folder)
        var entries: [Entry] = []
        do {
            switch location {
            case .album(_, let id):
                var cursor: String? = "0"
                while let next = cursor, !Task.isCancelled {
                    let page = try await client.json("/v1/albums/\(id)/items", query: ["cursor": next, "limit": "1000"])
                    entries += Self.entries(page["items"])
                    cursor = page["next"] as? String
                }
            case .folder(let device, let path):
                let page = try await client.json("/v1/files", query: ["path": path])
                entries = Self.entries(page["items"])
                folders["\(device)/\(path)"] = (page["items"] as? [[String: Any]] ?? []).compactMap { item in
                    guard item["kind"] as? String == "folder", let path = item["path"] as? String,
                          let name = item["name"] as? String else { return nil }
                    return PhoneFolder(path: path, name: name, count: item["count"] as? Int ?? 0)
                }
            }
        } catch let error as PhoneError {
            problems[location.deviceID] = error.message
            return
        } catch {
            return
        }

        // Only what Glimpse can show, with one local name each.
        var used = Set<String>()
        var wanted: [(entry: Entry, url: URL)] = []
        for entry in entries where entry.kind != "folder" {
            guard let type = UTType(filenameExtension: (entry.name as NSString).pathExtension),
                  FolderScanner.isSupported(type) else { continue }
            var name = entry.name
            if used.contains(name.lowercased()) {
                let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                name = "\(base) (\(entry.item)).\(ext)"
            }
            used.insert(name.lowercased())
            wanted.append((entry, folder.appendingPathComponent(name)))
        }

        // A file that left the phone leaves the cache too.
        let keep = Set(wanted.map { $0.url.standardizedFileURL.path })
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: .skipsHiddenFiles)) ?? []
        where !keep.contains(url.standardizedFileURL.path) && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            try? FileManager.default.removeItem(at: url)
            remote[url.standardizedFileURL.path] = nil
        }

        let missing = wanted.filter { item in
            let known = remote[item.url.standardizedFileURL.path]
            let exists = FileManager.default.fileExists(atPath: item.url.path)
            return !exists || known == nil || known!.modified != item.entry.modified
        }
        pending[location] = missing.count
        // Photos first, newest first, as small previews. Then videos and documents, the smallest first.
        let previews = missing.filter { $0.entry.kind == "image" }.sorted { $0.entry.modified > $1.entry.modified }
        let whole = missing.filter { $0.entry.kind != "image" }.sorted { $0.entry.size < $1.entry.size }

        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for item in previews {
                if Task.isCancelled { break }
                if running == 6 {
                    await group.next()
                    running -= 1
                }
                running += 1
                group.addTask { await self.fetchPreview(item.entry, at: item.url, device: location.deviceID, client: client, location: location) }
            }
        }
        saveManifest(in: folder)
        for item in whole where !Task.isCancelled {
            let file = RemoteFile(device: location.deviceID, item: item.entry.item, isFull: false,
                                  modified: item.entry.modified, created: item.entry.taken)
            await downloadFull(file, to: item.url)
            pending[location, default: 1] -= 1
        }
        saveManifest(in: folder)
        pending[location] = nil
    }

    private func fetchPreview(_ entry: Entry, at url: URL, device: String, client: PhoneClient, location: DeviceLocation) async {
        defer { pending[location, default: 1] -= 1 }
        guard let data = try? await client.data("/v1/items/\(entry.item)/thumbnail",
                                                query: ["size": String(Self.previewSize)]) else { return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).part")
        do {
            try data.write(to: temporary)
            // One second older than the phone's file: the full file then counts as a change, and the viewer reloads it.
            try place(temporary, at: url, modified: entry.modified.addingTimeInterval(-1), created: entry.taken)
            remote[url.standardizedFileURL.path] = RemoteFile(device: device, item: entry.item, isFull: false,
                                                              modified: entry.modified, created: entry.taken)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    /// Moves a downloaded file into place in one step, so the folder watcher never sees half a file.
    private func place(_ temporary: URL, at url: URL, modified: Date, created: Date?) throws {
        var attributes: [FileAttributeKey: Any] = [.modificationDate: modified]
        if let created { attributes[.creationDate] = created }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func entries(_ value: Any?) -> [Entry] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String, let kind = item["kind"] as? String
            else { return nil }
            let modified = (item["modified"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            let taken = (item["taken"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return Entry(item: id, name: name, kind: kind, size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                         modified: modified, taken: taken)
        }
    }

    // MARK: - Manifest

    /// The manifest of a cache folder remembers which files are previews, across launches.
    private func manifestURL(in folder: URL) -> URL { folder.appendingPathComponent(".glimpse-device.json") }

    private func loadManifest(in folder: URL) {
        guard let data = try? Data(contentsOf: manifestURL(in: folder)),
              let files = try? JSONDecoder().decode([String: RemoteFile].self, from: data) else { return }
        for (name, file) in files {
            remote[folder.appendingPathComponent(name).standardizedFileURL.path] = file
        }
    }

    private func loadManifestEntry(for url: URL) -> RemoteFile? {
        loadManifest(in: url.deletingLastPathComponent())
        return remote[url.standardizedFileURL.path]
    }

    private func saveManifest(in folder: URL) {
        let prefix = folder.standardizedFileURL.path + "/"
        var files: [String: RemoteFile] = [:]
        for (path, file) in remote where path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/") {
            files[String(path.dropFirst(prefix.count))] = file
        }
        try? JSONEncoder().encode(files).write(to: manifestURL(in: folder), options: .atomic)
    }

    // MARK: - Clients

    private func client(for deviceID: String) -> PhoneClient? {
        if let client = clients[deviceID] { return client }
        guard let phone = phones.first(where: { $0.id == deviceID }), let host = phone.host, let port = phone.port,
              let identity = PeerService.shared.identity else {
            problems[deviceID] = "Open Glimpse on the phone and turn on Share with your Mac."
            return nil
        }
        let client = PhoneClient(host: host, port: port, fingerprint: phone.fingerprint, identity: identity.identity)
        clients[deviceID] = client
        return client
    }
}
