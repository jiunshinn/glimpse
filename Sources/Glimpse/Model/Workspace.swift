import AppKit
import Observation

/// A list of files that Glimpse collects from all workspace folders.
enum SmartList: Hashable, Sendable {
    case starred
    case tag(String)

    var title: String {
        switch self {
        case .starred: "Starred"
        case .tag(let name): name
        }
    }
}

/// A folder that the user added to the workspace.
struct WorkspaceFolder: Identifiable, Hashable {
    var url: URL
    var isPinned: Bool

    var id: URL { url }
    var name: String { FileManager.default.displayName(atPath: url.path) }
}

extension Notification.Name {
    /// Posted when stars, tags or the files of the workspace folders change.
    static let workspaceFilesDidChange = Notification.Name("Glimpse.workspaceFilesDidChange")
    /// Posted when a file is pinned or unpinned. The viewers sort their files again.
    static let pinnedFilesDidChange = Notification.Name("Glimpse.pinnedFilesDidChange")
}

/// The folders, stars, tags and boards that all windows share, and the tabs that open again at launch.
@MainActor
@Observable
final class Workspace {
    static let shared = Workspace()

    private(set) var folders: [WorkspaceFolder] = []
    /// The paths of the starred files.
    private(set) var stars: Set<String> = []
    /// The paths of the pinned files. A pinned file comes first in its folder, in all sort orders.
    private(set) var pinnedFiles: Set<String> = []
    private(set) var boards: [Board] = []
    /// The board that B and "Add to Board" use.
    private(set) var lastBoardID: UUID?
    var reopenAtLaunch = true {
        didSet { if reopenAtLaunch != oldValue { scheduleSave() } }
    }

    // MARK: Index of the workspace folders

    /// The files of each workspace folder, from the last scan.
    private(set) var files: [URL: [ImageItem]] = [:]
    /// Folders that Glimpse cannot read, for example a folder that was deleted.
    private(set) var unreadableFolders: Set<URL> = []
    /// Files that arrived in a workspace folder while Glimpse was open. They lose the mark when the viewer shows them.
    private(set) var newFiles: Set<URL> = []
    /// The quick tags, then the other tags of the files in the workspace.
    private(set) var knownTags: [FinderTag] = FinderTag.quickTags
    /// The number of files with each tag, by tag name.
    private(set) var tagCounts: [String: Int] = [:]
    /// Changes when a tag changes. Views read it to update when tags change.
    private(set) var tagRevision = 0

    @ObservationIgnored private(set) var savedSession: [SavedWindow] = []
    @ObservationIgnored private var tagCache: [String: [FinderTag]] = [:]
    @ObservationIgnored private var bookmarks: [URL: Data] = [:]
    @ObservationIgnored private var watchers: [URL: FolderWatcher] = [:]
    @ObservationIgnored private var scanTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastFullScan = Date.distantPast
    @ObservationIgnored private let storeURL = Workspace.defaultStoreURL()

    private init() {
        load()
        folders.forEach { startWatching($0.url) }
        lastFullScan = Date()
        // Finder can change tags while Glimpse is in the background. Scan again when Glimpse becomes active.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescanAll() }
        }
    }

    /// The form of a folder URL that the workspace uses as a key.
    static func folderKey(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    // MARK: - Folders

    var allFiles: [ImageItem] { folders.flatMap { files[$0.url] ?? [] } }

    func contains(folder url: URL) -> Bool {
        folders.contains { $0.url.isSameFile(as: url) }
    }

    func folder(for url: URL) -> WorkspaceFolder? {
        folders.first { $0.url.isSameFile(as: url) }
    }

    func count(in folder: URL) -> Int { files[folder]?.count ?? 0 }

    func newCount(in folder: URL) -> Int {
        guard !newFiles.isEmpty else { return 0 }
        return files[folder]?.lazy.filter { self.newFiles.contains($0.url) }.count ?? 0
    }

    /// Adds the folders that are not in the workspace yet. Returns the added folders.
    @discardableResult
    func addFolders(_ urls: [URL]) -> [URL] {
        var added: [URL] = []
        for raw in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: raw.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  (try? raw.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
            else { continue }
            let url = Self.folderKey(raw)
            guard !contains(folder: url) else { continue }
            folders.append(WorkspaceFolder(url: url, isPinned: false))
            bookmarks[url] = try? url.bookmarkData()
            startWatching(url)
            added.append(url)
        }
        if !added.isEmpty { scheduleSave() }
        return added
    }

    /// Removes a folder from the workspace. The folder and its files stay on the disk.
    func removeFolder(_ url: URL) {
        guard let key = folder(for: url)?.url else { return }
        folders.removeAll { $0.url == key }
        watchers[key] = nil
        scanTasks[key]?.cancel()
        scanTasks[key] = nil
        files[key] = nil
        unreadableFolders.remove(key)
        bookmarks[key] = nil
        newFiles = newFiles.filter { !$0.deletingLastPathComponent().isSameFile(as: key) }
        recomputeTagSummary()
        NotificationCenter.default.post(name: .workspaceFilesDidChange, object: self)
        scheduleSave()
    }

    func setPinned(_ pinned: Bool, for url: URL) {
        guard let index = folders.firstIndex(where: { $0.url.isSameFile(as: url) }) else { return }
        folders[index].isPinned = pinned
        scheduleSave()
    }

    func isFolderPinned(_ url: URL) -> Bool {
        folder(for: url)?.isPinned ?? false
    }

    /// Pins a folder to Favorites, or unpins it. A folder that is not in the workspace is added first.
    /// Returns true if the folder is pinned now, or nil if Glimpse cannot add the folder.
    @discardableResult
    func toggleFolderPin(_ url: URL) -> Bool? {
        if isFolderPinned(url) {
            setPinned(false, for: url)
            return false
        }
        guard contains(folder: url) || !addFolders([url]).isEmpty else { return nil }
        setPinned(true, for: url)
        return true
    }

    func moveFolders(from source: IndexSet, to destination: Int) {
        folders.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    private func startWatching(_ url: URL) {
        watchers[url] = FolderWatcher(folder: url) { [weak self] in
            MainActor.assumeIsolated { self?.scan(url) }
        }
        scan(url)
    }

    private func rescanAll() {
        guard Date().timeIntervalSince(lastFullScan) > 3 else { return }
        lastFullScan = Date()
        folders.forEach { scan($0.url) }
    }

    private func scan(_ folder: URL) {
        scanTasks[folder]?.cancel()
        scanTasks[folder] = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (items: [ImageItem], tags: [String: [FinderTag]])? in
                guard let items = FolderScanner.scan(.folder(folder), sortedBy: .name, ascending: true) else { return nil }
                var tags: [String: [FinderTag]] = [:]
                for item in items { tags[item.url.path] = FinderTags.read(item.url) }
                return (items, tags)
            }.value
            guard let self, !Task.isCancelled, self.folders.contains(where: { $0.url == folder }) else { return }
            self.apply(result, to: folder)
        }
    }

    private func apply(_ result: (items: [ImageItem], tags: [String: [FinderTag]])?, to folder: URL) {
        guard let result else {
            files[folder] = []
            unreadableFolders.insert(folder)
            recomputeTagSummary()
            NotificationCenter.default.post(name: .workspaceFilesDidChange, object: self)
            return
        }
        unreadableFolders.remove(folder)
        let current = Set(result.items.map(\.url))
        if let old = files[folder] {
            let previous = Set(old.map(\.url))
            let arrived = current.subtracting(previous)
            let removed = previous.subtracting(current)
            if !arrived.isEmpty || !removed.isEmpty {
                newFiles = newFiles.subtracting(removed).union(arrived)
            }
        }
        if files[folder] != result.items { files[folder] = result.items }
        var tagsChanged = false
        for (path, tags) in result.tags where tagCache[path] != tags {
            tagCache[path] = tags
            tagsChanged = true
        }
        if tagsChanged { tagRevision += 1 }
        recomputeTagSummary()
        NotificationCenter.default.post(name: .workspaceFilesDidChange, object: self)
    }

    func markSeen(_ url: URL) {
        if newFiles.contains(url) { newFiles.remove(url) }
    }

    // MARK: - Stars

    func isStarred(_ url: URL) -> Bool {
        stars.contains(url.standardizedFileURL.path)
    }

    /// Returns true if the file is starred now.
    @discardableResult
    func toggleStar(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let starred = !stars.contains(path)
        if starred { stars.insert(path) } else { stars.remove(path) }
        scheduleSave()
        NotificationCenter.default.post(name: .workspaceFilesDidChange, object: self)
        return starred
    }

    // MARK: - Pinned files

    func isFilePinned(_ url: URL) -> Bool {
        pinnedFiles.contains(url.standardizedFileURL.path)
    }

    /// Returns true if the file is pinned now.
    @discardableResult
    func toggleFilePin(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let pinned = !pinnedFiles.contains(path)
        if pinned { pinnedFiles.insert(path) } else { pinnedFiles.remove(path) }
        scheduleSave()
        NotificationCenter.default.post(name: .pinnedFilesDidChange, object: self)
        return pinned
    }

    // MARK: - Tags

    func tags(for url: URL) -> [FinderTag] {
        _ = tagRevision
        let path = url.standardizedFileURL.path
        if let cached = tagCache[path] { return cached }
        let tags = FinderTags.read(url)
        tagCache[path] = tags
        return tags
    }

    func hasTag(_ name: String, _ url: URL) -> Bool {
        tags(for: url).contains { $0.name == name }
    }

    /// Adds the tag, or removes it if the file has it. Returns the new state, or nil if the file cannot change.
    @discardableResult
    func toggleTag(_ tag: FinderTag, for url: URL) -> Bool? {
        // Read the file again: Finder can have changed the tags.
        var tags = FinderTags.read(url)
        let added = !tags.contains { $0.name == tag.name }
        if added { tags.append(tag) } else { tags.removeAll { $0.name == tag.name } }
        guard FinderTags.write(tags, to: url) else { return nil }
        tagCache[url.standardizedFileURL.path] = tags
        tagRevision += 1
        recomputeTagSummary()
        NotificationCenter.default.post(name: .workspaceFilesDidChange, object: self)
        return added
    }

    private func recomputeTagSummary() {
        var counts: [String: Int] = [:]
        var others: [String: FinderTag] = [:]
        let quickNames = Set(FinderTag.quickTags.map(\.name))
        for item in allFiles {
            for tag in tagCache[item.url.path] ?? [] {
                counts[tag.name, default: 0] += 1
                if !quickNames.contains(tag.name), others[tag.name] == nil { others[tag.name] = tag }
            }
        }
        let known = FinderTag.quickTags + others.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if counts != tagCounts { tagCounts = counts }
        if known != knownTags { knownTags = known }
    }

    // MARK: - Smart lists

    func urls(for list: SmartList) -> [URL] {
        switch list {
        case .starred:
            return stars.sorted().map { URL(fileURLWithPath: $0) }
        case .tag(let name):
            return allFiles.filter { hasTag(name, $0.url) }.map(\.url)
        }
    }

    func count(of list: SmartList) -> Int {
        switch list {
        case .starred: stars.count
        case .tag(let name): tagCounts[name] ?? 0
        }
    }

    // MARK: - Boards

    func board(_ id: UUID) -> Board? {
        boards.first { $0.id == id }
    }

    /// The board that B and "Add to Board" use: the last board that a tab showed.
    var targetBoardID: UUID? {
        if let lastBoardID, board(lastBoardID) != nil { return lastBoardID }
        return boards.first?.id
    }

    @discardableResult
    func newBoard() -> Board {
        let names = Set(boards.map(\.name))
        var number = boards.count + 1
        while names.contains("Board \(number)") { number += 1 }
        let board = Board(name: "Board \(number)")
        boards.append(board)
        lastBoardID = board.id
        scheduleSave()
        return board
    }

    func renameBoard(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateBoard(id) { $0.name = trimmed }
    }

    func deleteBoard(_ id: UUID) {
        boards.removeAll { $0.id == id }
        if lastBoardID == id { lastBoardID = boards.first?.id }
        scheduleSave()
    }

    func noteBoardUsed(_ id: UUID) {
        guard lastBoardID != id else { return }
        lastBoardID = id
        scheduleSave()
    }

    /// Puts files on a board. A file that is on the board already is not added again. Returns the number of new items.
    @discardableResult
    func add(_ urls: [URL], to id: UUID, at point: CGPoint? = nil) -> Int {
        var added = 0
        updateBoard(id) { board in
            let existing = Set(board.items.compactMap(\.path))
            for (offset, url) in urls.enumerated() {
                let path = url.standardizedFileURL.path
                guard !existing.contains(path) else { continue }
                let count = board.items.count
                let origin = point.map { CGPoint(x: $0.x + CGFloat(offset) * 28, y: $0.y + CGFloat(offset) * 28) }
                    ?? CGPoint(x: 40 + CGFloat(count % 4) * 290, y: 40 + CGFloat(count / 4 % 4) * 270)
                board.items.append(BoardItem(path: path, x: max(0, origin.x), y: max(0, origin.y), width: 260))
                added += 1
            }
        }
        lastBoardID = id
        return added
    }

    @discardableResult
    func addNote(to id: UUID, at point: CGPoint) -> UUID {
        let item = BoardItem(note: "", x: point.x, y: point.y, width: 220)
        updateBoard(id) { $0.items.append(item) }
        return item.id
    }

    func updateItem(_ itemID: UUID, in id: UUID, _ change: (inout BoardItem) -> Void) {
        updateBoard(id) { board in
            guard let index = board.items.firstIndex(where: { $0.id == itemID }) else { return }
            change(&board.items[index])
        }
    }

    func removeItem(_ itemID: UUID, from id: UUID) {
        updateBoard(id) { $0.items.removeAll { $0.id == itemID } }
    }

    /// Puts the item on top of the others.
    func bringToFront(_ itemID: UUID, in id: UUID) {
        updateBoard(id) { board in
            guard let index = board.items.firstIndex(where: { $0.id == itemID }), index != board.items.count - 1 else { return }
            board.items.append(board.items.remove(at: index))
        }
    }

    /// Puts the items in rows that fit the width.
    func arrange(_ id: UUID, width: CGFloat) {
        updateBoard(id) { board in
            let margin = 28.0, gap = 18.0
            var x = margin, y = margin, rowHeight = 0.0
            for index in board.items.indices {
                let item = board.items[index]
                let itemWidth: Double = item.isNote ? 220 : (item.aspect ?? 1.33) < 1 ? 170 : 240
                var placed = item
                placed.width = itemWidth
                if x + itemWidth > Double(width) - margin, x > margin {
                    x = margin
                    y += rowHeight + gap + 22
                    rowHeight = 0
                }
                placed.x = x
                placed.y = y
                board.items[index] = placed
                x += itemWidth + gap
                rowHeight = max(rowHeight, placed.height)
            }
        }
    }

    private func updateBoard(_ id: UUID, _ change: (inout Board) -> Void) {
        guard let index = boards.firstIndex(where: { $0.id == id }) else { return }
        var board = boards[index]
        change(&board)
        guard board != boards[index] else { return }
        boards[index] = board
        scheduleSave()
    }

    // MARK: - Session

    func saveSession(_ windows: [SavedWindow]) {
        guard windows != savedSession else { return }
        savedSession = windows
        scheduleSave()
    }

    // MARK: - Storage

    private struct Stored: Codable {
        var folders: [StoredFolder] = []
        var stars: [String] = []
        var pinnedFiles: [String] = []
        var boards: [Board] = []
        var lastBoardID: UUID?
        var reopenAtLaunch = true
        var session: [SavedWindow] = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            folders = try container.decodeIfPresent([StoredFolder].self, forKey: .folders) ?? []
            stars = try container.decodeIfPresent([String].self, forKey: .stars) ?? []
            pinnedFiles = try container.decodeIfPresent([String].self, forKey: .pinnedFiles) ?? []
            boards = try container.decodeIfPresent([Board].self, forKey: .boards) ?? []
            lastBoardID = try container.decodeIfPresent(UUID.self, forKey: .lastBoardID)
            reopenAtLaunch = try container.decodeIfPresent(Bool.self, forKey: .reopenAtLaunch) ?? true
            session = (try? container.decodeIfPresent([SavedWindow].self, forKey: .session)) ?? []
        }
    }

    private struct StoredFolder: Codable {
        var path: String
        var bookmark: Data?
        var pinned: Bool?
    }

    private static func defaultStoreURL() -> URL {
        #if DEBUG
        // Development aid: GLIMPSE_WORKSPACE=/path/to/file.json keeps test runs away from the real workspace.
        if let path = ProcessInfo.processInfo.environment["GLIMPSE_WORKSPACE"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Glimpse", isDirectory: true).appendingPathComponent("Workspace.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        for entry in stored.folders {
            var url = Self.folderKey(URL(fileURLWithPath: entry.path))
            var bookmark = entry.bookmark
            // A bookmark finds a folder that was moved or renamed.
            if let data = entry.bookmark {
                var isStale = false
                if let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                           relativeTo: nil, bookmarkDataIsStale: &isStale) {
                    url = Self.folderKey(resolved)
                    if isStale { bookmark = try? url.bookmarkData() }
                }
            }
            guard !contains(folder: url) else { continue }
            folders.append(WorkspaceFolder(url: url, isPinned: entry.pinned ?? false))
            bookmarks[url] = bookmark
        }
        stars = Set(stored.stars)
        pinnedFiles = Set(stored.pinnedFiles)
        boards = stored.boards
        lastBoardID = stored.lastBoardID
        reopenAtLaunch = stored.reopenAtLaunch
        savedSession = stored.session
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        var stored = Stored()
        stored.folders = folders.map { StoredFolder(path: $0.url.path, bookmark: bookmarks[$0.url], pinned: $0.isPinned) }
        stored.stars = stars.sorted()
        stored.pinnedFiles = pinnedFiles.sorted()
        stored.boards = boards
        stored.lastBoardID = lastBoardID
        stored.reopenAtLaunch = reopenAtLaunch
        stored.session = savedSession
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: storeURL, options: .atomic)
        } catch {
            NSLog("Glimpse could not save the workspace: \(error.localizedDescription)")
        }
    }
}

// MARK: - Saved tabs

/// A tab that opens again at the next launch.
struct SavedTab: Codable, Equatable {
    enum Kind: String, Codable {
        case folder, files, starred, tag, board
    }

    var kind: Kind
    var path: String?
    var paths: [String]?
    var tag: String?
    var board: UUID?
    /// The file that the tab showed.
    var current: String?
    var grid = false
    var filter = TypeFilter()

    init(kind: Kind) {
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        paths = try container.decodeIfPresent([String].self, forKey: .paths)
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
        board = try container.decodeIfPresent(UUID.self, forKey: .board)
        current = try container.decodeIfPresent(String.self, forKey: .current)
        grid = try container.decodeIfPresent(Bool.self, forKey: .grid) ?? false
        filter = try container.decodeIfPresent(TypeFilter.self, forKey: .filter) ?? TypeFilter()
    }
}

/// A window and its tabs, in the order of the tab bar.
struct SavedWindow: Codable, Equatable {
    var tabs: [SavedTab]
    var selected: Int
    var frame: String?
}
