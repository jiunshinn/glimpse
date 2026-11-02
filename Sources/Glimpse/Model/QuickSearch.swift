import AppKit
import Observation

/// A command that Quick Search can run.
struct QuickCommand {
    let title: String
    let symbol: String
    var shortcut: String?
    let detail: String
    let run: @MainActor (ViewerWindowController) -> Void
}

/// Finds files, folders, tags, boards and commands in the workspace. ⌘K opens it.
@MainActor
@Observable
final class QuickSearchModel {
    enum Mode {
        /// ↵ opens the result. A folder that a tab shows already opens in that tab.
        case open
        /// The tab is new: ↵ opens the result in this tab.
        case newTab
        /// ↵ puts the file on the board.
        case addToBoard
    }

    struct Result: Identifiable {
        enum Kind {
            case file(ImageItem)
            case folder(URL)
            case smart(SmartList)
            case board(UUID)
            case command(QuickCommand)
        }

        let id: String
        let kind: Kind
        let title: String
        /// The positions of the characters in the title that match the query.
        let matches: [Int]
        let subtitle: String
        let accessory: String
        fileprivate let score: Int
    }

    struct Group: Identifiable {
        let title: String
        let results: [Result]
        fileprivate var best = 0
        var id: String { title }
    }

    private(set) var isVisible = false
    private(set) var mode: Mode = .open
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            selection = 0
            refresh()
        }
    }
    private(set) var groups: [Group] = []
    private(set) var results: [Result] = []
    var selection = 0

    @ObservationIgnored weak var controller: ViewerWindowController?

    var selected: Result? { results.indices.contains(selection) ? results[selection] : nil }

    func show(_ mode: Mode) {
        self.mode = mode
        query = ""
        selection = 0
        refresh()
        isVisible = true
    }

    func hide() {
        isVisible = false
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func activate(_ index: Int? = nil, modifiers: NSEvent.ModifierFlags = []) {
        let index = index ?? selection
        guard results.indices.contains(index) else { return }
        let result = results[index]
        let mode = self.mode
        hide()
        controller?.run(result, mode: mode, modifiers: modifiers)
    }

    // MARK: - Searching

    private static let filterNames: Set<String> = ["type", "tag", "in", "is"]

    private func refresh() {
        var filters: [String: String] = [:]
        var words: [String] = []
        for token in query.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let colon = token.firstIndex(of: ":"), Self.filterNames.contains(token[..<colon].lowercased()) {
                filters[token[..<colon].lowercased()] = String(token[token.index(after: colon)...]).lowercased()
            } else {
                words.append(token)
            }
        }
        let text = words.joined(separator: " ")
        let found = text.isEmpty && filters.isEmpty ? suggestions() : search(text, filters: filters)
        groups = found.filter { !$0.results.isEmpty }
        results = groups.flatMap(\.results)
        if selection >= results.count { selection = max(0, results.count - 1) }
    }

    private func search(_ text: String, filters: [String: String]) -> [Group] {
        let workspace = Workspace.shared
        var files = searchableFiles()
        if let type = filters["type"] { files = files.filter { Self.matches(type: type, $0) } }
        if let tag = filters["tag"] {
            files = files.filter { item in workspace.tags(for: item.url).contains { $0.name.lowercased().hasPrefix(tag) } }
        }
        if let folder = filters["in"] {
            files = files.filter { Self.folderName(of: $0.url).lowercased().contains(folder) }
        }
        if let state = filters["is"] {
            files = files.filter { item in
                if !state.isEmpty && "new".hasPrefix(state) { return workspace.newFiles.contains(item.url) }
                if !state.isEmpty && "pinned".hasPrefix(state) { return workspace.isFilePinned(item.url) }
                return workspace.isStarred(item.url)
            }
        }

        var groups: [Group] = []
        let fileResults: [Result]
        if text.isEmpty {
            fileResults = files.prefix(14).map { fileResult($0, matches: [], score: 0) }
        } else {
            fileResults = files.compactMap { item in
                FuzzyMatch.match(text, in: item.name).map { fileResult(item, matches: $0.indices, score: $0.score) }
            }
            .sorted { $0.score > $1.score }
            .prefix(8).map { $0 }
        }
        let filterText = filters.map { "\($0.key):\($0.value)" }.sorted().joined(separator: " ")
        groups.append(Group(title: filters.isEmpty ? "Files" : "Files · \(filterText)", results: fileResults,
                            best: fileResults.first?.score ?? 0))
        guard !text.isEmpty, filters.isEmpty, mode != .addToBoard else { return groups }

        let folders = workspace.folders.compactMap { folder in
            FuzzyMatch.match(text, in: folder.name).map { folderResult(folder.url, matches: $0.indices, score: $0.score) }
        }.sorted { $0.score > $1.score }
        groups.append(Group(title: "Folders", results: folders, best: folders.first?.score ?? 0))

        let lists = [SmartList.starred] + workspace.knownTags.map { SmartList.tag($0.name) }
        let smart = lists.compactMap { list in
            FuzzyMatch.match(text, in: list.title).map { smartResult(list, matches: $0.indices, score: $0.score) }
        }.sorted { $0.score > $1.score }
        groups.append(Group(title: "Favorites and Tags", results: smart, best: smart.first?.score ?? 0))

        let boards = workspace.boards.compactMap { board in
            FuzzyMatch.match(text, in: board.name).map { boardResult(board, matches: $0.indices, score: $0.score) }
        }.sorted { $0.score > $1.score }
        groups.append(Group(title: "Boards", results: boards, best: boards.first?.score ?? 0))

        let commands = commands().compactMap { command in
            FuzzyMatch.match(text, in: command.title).map { commandResult(command, matches: $0.indices, score: $0.score) }
        }.sorted { $0.score > $1.score }.prefix(5).map { $0 }
        // A command ranks below a file or a folder with the same score.
        groups.append(Group(title: "Commands", results: commands, best: (commands.first?.score ?? 0) - 20))

        return groups.sorted { $0.best > $1.best }
    }

    private func suggestions() -> [Group] {
        let workspace = Workspace.shared
        switch mode {
        case .addToBoard:
            let starred = workspace.urls(for: .starred).compactMap(FolderScanner.item(for:))
            let recent = recentFiles().filter { !workspace.isStarred($0.url) }
            return [
                Group(title: "Starred", results: starred.prefix(12).map { fileResult($0, matches: [], score: 0) }),
                Group(title: "Recent Files", results: recent.prefix(6).map { fileResult($0, matches: [], score: 0) }),
            ]
        case .newTab:
            let lists = [SmartList.starred] + workspace.knownTags.map { SmartList.tag($0.name) }
            return [
                Group(title: "Folders", results: workspace.folders.map { folderResult($0.url, matches: [], score: 0) }),
                Group(title: "Favorites and Tags", results: lists.map { smartResult($0, matches: [], score: 0) }),
                Group(title: "Boards", results: workspace.boards.map { boardResult($0, matches: [], score: 0) }),
                Group(title: "Recent Files", results: recentFiles().prefix(5).map { fileResult($0, matches: [], score: 0) }),
            ]
        case .open:
            return [
                Group(title: "Recent Files", results: recentFiles().prefix(5).map { fileResult($0, matches: [], score: 0) }),
                Group(title: "Folders", results: workspace.folders.prefix(5).map { folderResult($0.url, matches: [], score: 0) }),
                Group(title: "Commands", results: commands().prefix(5).map { commandResult($0, matches: [], score: 0) }),
            ]
        }
    }

    /// The files of the workspace folders, and the files of this tab.
    private func searchableFiles() -> [ImageItem] {
        var seen = Set<String>()
        var files: [ImageItem] = []
        for item in Workspace.shared.allFiles + (controller?.model.allItems ?? []) where seen.insert(item.url.path).inserted {
            files.append(item)
        }
        return files
    }

    private func recentFiles() -> [ImageItem] {
        NSDocumentController.shared.recentDocumentURLs.compactMap(FolderScanner.item(for:))
    }

    private func commands() -> [QuickCommand] {
        let workspace = Workspace.shared
        let showsViewer = controller?.tab.boardID == nil
        var commands = [
            QuickCommand(title: "Add Folder to Workspace…", symbol: "folder.badge.plus", shortcut: "⇧⌘O",
                         detail: "Add a folder to the sidebar. Glimpse watches the folder for new files.") { _ in
                NSApp.sendAction(#selector(AppDelegate.addFolderToWorkspace(_:)), to: nil, from: nil)
            },
            QuickCommand(title: "New Tab", symbol: "plus.square.on.square", shortcut: "⌘T",
                         detail: "Open a new tab in this window.") { $0.newWindowForTab(nil) },
            QuickCommand(title: "New Board", symbol: "rectangle.3.group", detail: "Make an empty board and open it in a new tab.") {
                $0.newBoard(nil)
            },
            QuickCommand(title: "Open Starred Files", symbol: "star", detail: "Show the starred files from all folders.") {
                $0.present(.request(.smart(.starred)), placement: .reuseOrCurrent)
            },
            QuickCommand(title: workspace.reopenAtLaunch ? "Turn Off Reopen at Launch" : "Turn On Reopen at Launch",
                         symbol: "clock.arrow.circlepath",
                         detail: "When it is on, Glimpse opens the same tabs, files, views and filters at the next launch.") { _ in
                Workspace.shared.reopenAtLaunch.toggle()
            },
            QuickCommand(title: "Show or Hide the Sidebar", symbol: "sidebar.left", shortcut: "⌃⌘S",
                         detail: "The sidebar shows the folders, tags and boards of the workspace.") {
                $0.toggleSidebar(nil)
            },
        ]
        if showsViewer {
            let filters: [(String, String, ItemKind?)] = [
                ("Show Only Images", "photo", .image), ("Show Only Videos", "film", .video),
                ("Show Only Documents", "doc.richtext", .document), ("Show All File Types", "line.3.horizontal.decrease.circle", nil),
            ]
            commands.insert(contentsOf: filters.map { title, symbol, kind in
                QuickCommand(title: title, symbol: symbol, detail: "Filter this tab. The arrow keys skip the other files.") {
                    $0.model.filter = TypeFilter(kind: kind)
                }
            }, at: 3)
            commands.append(QuickCommand(title: "Show the Grid or the Viewer", symbol: "square.grid.2x2", shortcut: "G",
                                         detail: "Switch between the grid of the folder and one file.") {
                $0.model.toggleGrid()
            })
            if let file = controller?.model.current {
                let pinned = workspace.isFilePinned(file.url)
                commands.append(QuickCommand(title: pinned ? "Unpin “\(file.name)” from the Top" : "Pin “\(file.name)” to the Top",
                                             symbol: pinned ? "pin.slash" : "pin", shortcut: "P",
                                             detail: "A pinned file comes first in its folder, in every sort order.") {
                    $0.model.toggleFilePin(file.url)
                })
            }
            if let folder = controller?.model.currentFolder {
                let name = FileManager.default.displayName(atPath: folder.path)
                let pinned = workspace.isFolderPinned(folder)
                commands.append(QuickCommand(title: pinned ? "Unpin “\(name)” from Favorites" : "Pin “\(name)” to Favorites",
                                             symbol: pinned ? "pin.slash" : "pin", shortcut: "⇧P",
                                             detail: "Favorites in the sidebar show the pinned folders. A folder that is not in the workspace is added too.") {
                    $0.model.toggleFolderPin(folder)
                })
            }
        }
        if let folder = controller?.folderOutsideWorkspace {
            let name = FileManager.default.displayName(atPath: folder.path)
            commands.insert(QuickCommand(title: "Add “\(name)” to Workspace", symbol: "folder.badge.plus",
                                         detail: "Add the folder of this tab to the sidebar.") {
                $0.addCurrentFolderToWorkspace(nil)
            }, at: 0)
        }
        return commands
    }

    // MARK: - Results

    private func fileResult(_ item: ImageItem, matches: [Int], score: Int) -> Result {
        Result(id: "file:" + item.url.path, kind: .file(item), title: item.name, matches: matches,
               subtitle: Self.folderName(of: item.url), accessory: "", score: score)
    }

    private func folderResult(_ url: URL, matches: [Int], score: Int) -> Result {
        let count = Workspace.shared.count(in: url)
        return Result(id: "folder:" + url.path, kind: .folder(url), title: FileManager.default.displayName(atPath: url.path),
                      matches: matches, subtitle: (url.path as NSString).abbreviatingWithTildeInPath,
                      accessory: count == 1 ? "1 file" : "\(count) files", score: score)
    }

    private func smartResult(_ list: SmartList, matches: [Int], score: Int) -> Result {
        let count = Workspace.shared.count(of: list)
        let kind = switch list {
        case .starred: "Favorites"
        case .tag: "Tag"
        }
        return Result(id: "smart:" + list.title, kind: .smart(list), title: list.title, matches: matches, subtitle: kind,
                      accessory: count == 1 ? "1 file" : "\(count) files", score: score)
    }

    private func boardResult(_ board: Board, matches: [Int], score: Int) -> Result {
        Result(id: "board:" + board.id.uuidString, kind: .board(board.id), title: board.name, matches: matches,
               subtitle: "Board", accessory: board.items.count == 1 ? "1 item" : "\(board.items.count) items", score: score)
    }

    private func commandResult(_ command: QuickCommand, matches: [Int], score: Int) -> Result {
        Result(id: "command:" + command.title, kind: .command(command), title: command.title, matches: matches,
               subtitle: "Command", accessory: command.shortcut ?? "", score: score)
    }

    static func folderName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
    }

    /// type:video, type:images, type:doc, type:raw or a format such as type:heic.
    private static func matches(type: String, _ item: ImageItem) -> Bool {
        let value = type.hasSuffix("s") ? String(type.dropLast()) : type
        guard !value.isEmpty else { return true }
        if "image".hasPrefix(value) || value == "photo" { return item.kind == .image }
        if "video".hasPrefix(value) || value == "movie" { return item.kind == .video }
        if "document".hasPrefix(value) || value == "doc" { return item.kind == .document }
        if value == "raw" { return ["DNG", "CR2", "CR3", "NEF", "ARW", "RAF", "ORF", "RW2"].contains(item.format) }
        return item.format.lowercased() == value || (value == "jpeg" && item.format == "JPG")
    }
}

/// Matches a query against a name, as launchers do: the letters must come in order, but not side by side.
enum FuzzyMatch {
    /// Returns a score (higher is better) and the positions of the matching characters, or nil.
    static func match(_ query: String, in text: String) -> (score: Int, indices: [Int])? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (0, []) }
        // Part of the name, as typed, ranks first. A match at the start ranks highest.
        if let range = text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            let score = 200 - start + (start == 0 ? 60 : 0) - text.count / 5
            return (score, Array(start..<start + length))
        }
        let wanted = trimmed.filter { !$0.isWhitespace }.map { String($0).lowercased() }
        let characters = Array(text)
        var indices: [Int] = []
        var score = 0
        var last = -2
        var next = 0
        for (index, character) in characters.enumerated() where next < wanted.count {
            guard String(character).lowercased() == wanted[next] else { continue }
            let startsWord = index == 0 || " _-.·".contains(characters[index - 1])
            score += (index == last + 1 ? 5 : 1) + (startsWord ? 3 : 0)
            indices.append(index)
            last = index
            next += 1
        }
        return next == wanted.count ? (score, indices) : nil
    }
}
