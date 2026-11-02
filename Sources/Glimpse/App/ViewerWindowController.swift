import AppKit
import Carbon.HIToolbox
import SwiftUI

private extension NSToolbarItem.Identifier {
    static let rotate = Self("rotate")
    static let trash = Self("trash")
    static let share = Self("share")
    static let sort = Self("sort")
    static let filter = Self("filter")
    static let grid = Self("grid")
    static let info = Self("info")
    static let search = Self("search")
    static let addFiles = Self("addFiles")
    static let addNote = Self("addNote")
    static let arrange = Self("arrange")
}

/// One tab of a Glimpse window. A tab shows a folder, a list of files, a smart list or a board.
/// Each tab is a window. The windows of one tab bar share the frame.
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate,
    NSMenuItemValidation, NSToolbarItemValidation, NSSharingServicePickerToolbarItemDelegate {
    let model: ViewerModel
    let tab: TabState
    var onClose: ((ViewerWindowController) -> Void)?

    private let splitController: NSSplitViewController
    private let sidebarItem: NSSplitViewItem
    /// The view of the viewer or the board, right of the sidebar.
    private let contentView: NSView
    private let filterMenu = NSMenu(title: "File Types")
    /// Toolbars with one identifier have the same items in all windows. A board tab has other buttons, so it has its own toolbar.
    private let viewerToolbar = NSToolbar(identifier: "Glimpse.Viewer")
    private let boardToolbar = NSToolbar(identifier: "Glimpse.Board")
    private var monitors: [Any] = []
    private var observations: [NSKeyValueObservation] = []
    /// The sidebar closes in full screen. This is its state before full screen.
    private var sidebarWasCollapsed = false
    private var isChangingFullScreen = false

    init(cascadingFrom previous: NSWindow?, frame: NSRect? = nil) {
        let model = ViewerModel()
        let tab = TabState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // Windows with the same identifier share one tab bar.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "Glimpse.Viewer"
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 640, height: 420)

        let content = NSHostingController(rootView: TabContentView(model: model, tab: tab))
        content.sizingOptions = []
        // The window controller owns the title, the subtitle and the toolbar. Do not let SwiftUI change them.
        content.sceneBridgingOptions = []
        let sidebar = NSHostingController(rootView: SidebarView(tab: tab))
        sidebar.sizingOptions = []
        sidebar.sceneBridgingOptions = []

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !Preferences.showSidebar
        let splitController = NSSplitViewController()
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: content))
        splitController.splitView.autosaveName = "Glimpse.Sidebar"

        self.model = model
        self.tab = tab
        self.splitController = splitController
        self.sidebarItem = sidebarItem
        self.contentView = content.view
        super.init(window: window)

        tab.controller = self
        window.delegate = self
        for toolbar in [viewerToolbar, boardToolbar] {
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
        }
        window.toolbar = viewerToolbar
        window.contentViewController = splitController
        filterMenu.delegate = self

        placeWindow(window, after: previous, frame: frame)
        installEventMonitors()
        observeLayout()
        observeModel()
        updateTitlebarHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func placeWindow(_ window: NSWindow, after previous: NSWindow?, frame: NSRect?) {
        let isOnScreen = { (rect: NSRect) in NSScreen.screens.contains { $0.visibleFrame.intersects(rect) } }
        if let frame, isOnScreen(frame) {
            window.setFrame(frame, display: false)
        } else if let previous {
            window.setFrame(previous.frame, display: false)
            let topLeft = NSPoint(x: previous.frame.minX, y: previous.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        } else if let saved = Preferences.windowFrame, isOnScreen(saved) {
            window.setFrame(saved, display: false)
        } else if let screen = NSScreen.main?.visibleFrame {
            let size = NSSize(width: (screen.width * 0.72).rounded(), height: (screen.height * 0.8).rounded())
            window.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                   width: size.width, height: size.height), display: false)
        }
    }

    // MARK: - Content

    /// True for a tab that shows nothing yet.
    var isBlank: Bool { model.isBlank && tab.boardID == nil }

    /// Shows a folder, files or a smart list in this tab. The filter of the tab is for one folder only.
    func open(_ request: OpenRequest) {
        let isSameSource: Bool
        switch request {
        case .folder(let url, _):
            if case .folder(let folder) = model.source { isSameSource = folder.isSameFile(as: url) } else { isSameSource = false }
        case .files(let urls): isSameSource = model.source == .files(urls)
        case .smart(let list): isSameSource = model.source == .smart(list)
        }
        leaveBoard()
        model.open(request)
        if !isSameSource { model.filter = TypeFilter() }
    }

    func showBoard(_ id: UUID) {
        guard Workspace.shared.board(id) != nil else { return }
        tab.quickSearch.hide()
        model.close()
        tab.boardID = id
        tab.boardSelection = nil
        Workspace.shared.noteBoardUsed(id)
        configureToolbar()
    }

    /// Empties the tab. It shows the empty state.
    func showNothing() {
        leaveBoard()
        model.close()
    }

    private func leaveBoard() {
        guard tab.boardID != nil else { return }
        tab.boardID = nil
        tab.boardSelection = nil
        configureToolbar()
    }

    func apply(_ target: TabTarget) {
        switch target {
        case .request(let request): open(request)
        case .board(let id): showBoard(id)
        }
    }

    /// True if this tab shows the folder, the smart list or the board of the target.
    func shows(_ target: TabTarget) -> Bool {
        switch target {
        case .board(let id):
            return tab.boardID == id
        case .request(.folder(let url, _)):
            guard tab.boardID == nil, case .folder(let folder) = model.source else { return false }
            return folder.isSameFile(as: url)
        case .request(.smart(let list)):
            return tab.boardID == nil && model.source == .smart(list)
        case .request(.files):
            return false
        }
    }

    /// The folder of this tab, if the workspace does not have it.
    var folderOutsideWorkspace: URL? {
        guard tab.boardID == nil, case .folder(let url) = model.source, !Workspace.shared.contains(folder: url) else { return nil }
        return url
    }

    @discardableResult
    func present(_ target: TabTarget, placement: TabPlacement) -> ViewerWindowController {
        appDelegate?.present(target, from: self, placement: placement) ?? self
    }

    func openSidebarItem(_ item: SidebarItem, inNewTab: Bool) {
        let target: TabTarget
        switch item {
        case .smart(let list): target = .request(.smart(list))
        case .folder(let url), .pinned(let url): target = .request(.folder(url, selecting: nil))
        case .board(let id): target = .board(id)
        }
        let shown = present(target, placement: inNewTab ? .newTab : .reuseOrCurrent)
        shown.tab.sidebarSelection = item
    }

    func openFromBoard(_ url: URL) {
        present(.request(.folder(url.deletingLastPathComponent(), selecting: url)), placement: .reuseOrCurrent)
    }

    /// Runs a Quick Search result.
    func run(_ result: QuickSearchModel.Result, mode: QuickSearchModel.Mode, modifiers: NSEvent.ModifierFlags) {
        let placement: TabPlacement
        if mode != .newTab && modifiers.contains(.command) {
            placement = .newTab
        } else {
            // A new tab opens the result in itself, not in another tab that shows it.
            placement = mode == .newTab ? .current : .reuseOrCurrent
        }
        switch result.kind {
        case .file(let item):
            if mode == .addToBoard || modifiers.contains(.option) {
                addToBoard([item.url])
            } else {
                present(.request(.folder(item.url.deletingLastPathComponent(), selecting: item.url)), placement: placement)
            }
        case .folder(let url):
            present(.request(.folder(url, selecting: nil)), placement: placement)
        case .smart(let list):
            present(.request(.smart(list)), placement: placement)
        case .board(let id):
            present(.board(id), placement: placement)
        case .command(let command):
            command.run(self)
        }
    }

    /// Puts files on the board of this tab, or on the last board that a tab showed.
    func addToBoard(_ urls: [URL]) {
        let workspace = Workspace.shared
        let id = tab.boardID ?? workspace.targetBoardID ?? workspace.newBoard().id
        let added = workspace.add(urls, to: id)
        let name = workspace.board(id)?.name ?? "Board"
        model.showToast(added > 0 ? "Added to \(name)" : "On \(name) already", symbol: "rectangle.3.group")
    }

    func deleteBoard(_ id: UUID) {
        appDelegate?.closeBoardTabs(id)
        Workspace.shared.deleteBoard(id)
    }

    /// The tab as it opens again at the next launch. Nil for a tab that shows nothing.
    func savedTab() -> SavedTab? {
        if let id = tab.boardID {
            var saved = SavedTab(kind: .board)
            saved.board = id
            return saved
        }
        var saved: SavedTab
        switch model.source {
        case .folder(let url):
            saved = SavedTab(kind: .folder)
            saved.path = url.path
        case .files(let urls):
            saved = SavedTab(kind: .files)
            saved.paths = urls.map(\.path)
        case .smart(.starred):
            saved = SavedTab(kind: .starred)
        case .smart(.tag(let name)):
            saved = SavedTab(kind: .tag)
            saved.tag = name
        case nil:
            return nil
        }
        saved.current = model.current?.url.path
        saved.grid = model.isGridMode
        saved.filter = model.filter
        return saved
    }

    func restore(_ saved: SavedTab) {
        let manager = FileManager.default
        let current = saved.current.map { URL(fileURLWithPath: $0) }.flatMap { manager.fileExists(atPath: $0.path) ? $0 : nil }
        defer { model.filter = saved.filter }
        switch saved.kind {
        case .board:
            if let id = saved.board { showBoard(id) }
            return
        case .folder:
            guard let path = saved.path else { return }
            open(.folder(URL(fileURLWithPath: path, isDirectory: true), selecting: current))
        case .files:
            let urls = (saved.paths ?? []).map { URL(fileURLWithPath: $0) }.filter { manager.fileExists(atPath: $0.path) }
            open(.files(urls))
        case .starred:
            open(.smart(.starred))
        case .tag:
            guard let name = saved.tag else { return }
            open(.smart(.tag(name)))
        }
        if saved.grid, current != nil { model.setGridMode(true) }
    }

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    // MARK: - Model observation

    private func observeModel() {
        withObservationTracking {
            syncWindow()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observeModel() }
            }
        }
    }

    private func syncWindow() {
        guard let window else { return }
        if let id = tab.boardID {
            let board = Workspace.shared.board(id)
            window.title = board?.name ?? "Board"
            let count = board?.items.count ?? 0
            window.subtitle = count == 1 ? "1 item" : "\(count) items"
            window.tab.title = window.title
            window.representedURL = nil
        } else {
            window.title = model.windowTitle
            window.subtitle = model.windowSubtitle
            // The tab bar shows the folder, not the file.
            window.tab.title = model.collectionName
            // The icon next to the title. Drag it to take the file to another app.
            window.representedURL = model.isGridMode ? nil : model.current?.url
        }
        let isGrid = model.isGridMode
        let showInfo = model.showInfo
        let isFiltered = model.filter.isActive
        for item in window.toolbar?.items ?? [] {
            switch item.itemIdentifier {
            case .grid:
                item.image = symbol(isGrid ? "square.grid.2x2.fill" : "square.grid.2x2", "Grid")
            case .info:
                item.image = symbol(showInfo ? "info.circle.fill" : "info.circle", "Info")
            case .filter:
                item.image = symbol(isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                                    "File Types")
            default:
                break
            }
        }
        updateSidebarSelection()
        appDelegate?.sessionDidChange()
    }

    /// The sidebar shows the row of the folder, the smart list or the board of this tab.
    private func updateSidebarSelection() {
        let canonical: SidebarItem?
        if let id = tab.boardID {
            canonical = .board(id)
        } else {
            switch model.source {
            case .folder(let url): canonical = Workspace.shared.folder(for: url).map { .folder($0.url) }
            case .smart(let list): canonical = .smart(list)
            default: canonical = nil
            }
        }
        // A pinned folder in Favorites shows the same folder as its row in Folders.
        if case .pinned(let url) = tab.sidebarSelection, case .folder(let folder) = canonical, url == folder { return }
        if tab.sidebarSelection != canonical { tab.sidebarSelection = canonical }
    }

    private func updateTitlebarHeight() {
        guard let window else { return }
        // The titlebar, the toolbar and the tab bar. The content goes under them.
        let height = window.frame.height - window.contentLayoutRect.height
        if abs(model.titlebarHeight - height) > 0.5 { model.titlebarHeight = max(0, height) }
    }

    private func observeLayout() {
        guard let window else { return }
        observations = [
            // The tab bar appears with the second tab. It changes the area under the titlebar.
            window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateTitlebarHeight() }
            },
            sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isChangingFullScreen, self.window?.styleMask.contains(.fullScreen) == false else { return }
                    Preferences.showSidebar = !item.isCollapsed
                }
            },
        ]
    }

    // MARK: - Events

    private func installEventMonitors() {
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window, self.window?.attachedSheet == nil else { return false }
                return self.handleKeyDown(event)
            }
            return handled ? nil : event
        }
        let mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel]
        ) { [weak self] event in
            let location = event.locationInWindow
            let window = event.window
            MainActor.assumeIsolated {
                guard let self, window === self.window, self.tab.boardID == nil else { return }
                let view = self.contentView
                let point = view.convert(location, from: nil)
                // The pointer over the sidebar is not near the left edge of the image.
                guard view.bounds.contains(point) else {
                    self.model.pointerExited()
                    return
                }
                let topLeft = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
                self.model.pointerMoved(to: topLeft, in: view.bounds.size)
            }
            return event
        }
        monitors = [keyMonitor, mouseMonitor].compactMap { $0 }
    }

    private func modifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
    }

    /// Single keys without ⌘. Commands with ⌘ go through the menus.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if tab.quickSearch.isVisible { return handleQuickSearchKey(event) }
        // A text field gets all keys, for example the password field of a locked PDF or a note on a board.
        if let text = window?.firstResponder as? NSText, text.isEditable { return false }
        let flags = modifiers(of: event)
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let shift = flags.contains(.shift)
        if tab.boardID != nil { return handleBoardKey(event) }

        // While a document shows, the document view gets these keys and scrolls. ← → still change the file.
        if model.showsDocument, Self.documentScrollKeys.contains(Int(event.keyCode)) {
            model.focusDocument()
            return false
        }

        switch Int(event.keyCode) {
        case kVK_LeftArrow where shift && model.showsVideo: model.seekVideo(by: -5)
        case kVK_RightArrow where shift && model.showsVideo: model.seekVideo(by: 5)
        case kVK_LeftArrow: model.moveSelection(by: -1, vertical: false)
        case kVK_RightArrow: model.moveSelection(by: 1, vertical: false)
        case kVK_UpArrow: model.moveSelection(by: -1, vertical: true)
        case kVK_DownArrow: model.moveSelection(by: 1, vertical: true)
        case kVK_Home: model.first()
        case kVK_End: model.last()
        case kVK_PageUp: model.page(by: -1)
        case kVK_PageDown: model.page(by: 1)
        case kVK_Space:
            if model.isGridMode {
                model.openViewer(at: model.index)
            } else if model.showsVideo && !shift {
                model.togglePlayback()
            } else {
                shift ? model.previous() : model.next()
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard model.isGridMode, model.hasItems else { return false }
            model.openViewer(at: model.index)
        case kVK_Escape:
            return handleEscape()
        case kVK_ANSI_KeypadPlus: model.showsVideo ? model.changeVolume(by: 0.1) : model.zoomIn()
        case kVK_ANSI_KeypadMinus: model.showsVideo ? model.changeVolume(by: -0.1) : model.zoomOut()
        default:
            return handleCharacterKey(event, shift: shift)
        }
        return true
    }

    private static let documentScrollKeys: Set<Int> = [
        kVK_UpArrow, kVK_DownArrow, kVK_PageUp, kVK_PageDown, kVK_Home, kVK_End, kVK_Space,
    ]

    private func handleCharacterKey(_ event: NSEvent, shift: Bool) -> Bool {
        let character = KeyboardLayout.character(for: event)
        if model.showsVideo, handleVideoKey(character) { return true }
        switch character {
        case "g": model.toggleGrid()
        case "i": model.showInfo.toggle()
        case "t": model.showThumbnails.toggle()
        case "f": window?.toggleFullScreen(nil)
        case "z": model.toggleZoom()
        case "r": model.rotate(by: shift ? -1 : 1)
        case "=", "+": model.zoomIn()
        case "-", "_": model.zoomOut()
        case "?", "/": model.showShortcuts.toggle()
        case "s": model.toggleStar()
        case "b": addCurrentToBoard()
        case let digit? where ("1"..."5").contains(digit):
            guard let number = digit.wholeNumberValue else { return false }
            model.toggleTag(FinderTag.quickTags[number - 1])
        default: return false
        }
        return true
    }

    /// Keys of common video players. They work while a video shows.
    private func handleVideoKey(_ character: Character?) -> Bool {
        switch character {
        case "k": model.togglePlayback()
        case "j": model.seekVideo(by: -10)
        case "l": model.seekVideo(by: 10)
        case ",", "<": model.stepVideoFrame(by: -1)
        case ".", ">": model.stepVideoFrame(by: 1)
        case "[", "{": model.changeVideoSpeed(by: -1)
        case "]", "}": model.changeVideoSpeed(by: 1)
        case "\\", "|": model.resetVideoSpeed()
        case "=", "+": model.changeVolume(by: 0.1)
        case "-", "_": model.changeVolume(by: -0.1)
        case "m": model.toggleMute()
        default: return false
        }
        return true
    }

    /// ↑ ↓ choose a result and ↵ opens it. The search field gets the other keys.
    private func handleQuickSearchKey(_ event: NSEvent) -> Bool {
        // An input method (for example Korean) can use the keys to finish a character.
        if let text = window?.firstResponder as? NSTextView, text.hasMarkedText() { return false }
        let search = tab.quickSearch
        switch Int(event.keyCode) {
        case kVK_UpArrow: search.moveSelection(by: -1)
        case kVK_DownArrow: search.moveSelection(by: 1)
        case kVK_Return, kVK_ANSI_KeypadEnter: search.activate(modifiers: modifiers(of: event))
        case kVK_Escape: search.hide()
        default: return false
        }
        return true
    }

    private func handleBoardKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            guard let id = tab.boardID, let selection = tab.boardSelection else { return false }
            Workspace.shared.removeItem(selection, from: id)
            tab.boardSelection = nil
        case kVK_Escape:
            if tab.boardSelection != nil {
                tab.boardSelection = nil
            } else if let window, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                return false
            }
        default:
            guard KeyboardLayout.character(for: event) == "f" else { return false }
            window?.toggleFullScreen(nil)
        }
        return true
    }

    private func handleEscape() -> Bool {
        if model.showShortcuts {
            model.showShortcuts = false
        } else if let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else if model.isGridMode, model.current != nil, model.hasViewerContent {
            model.setGridMode(false)
        } else if model.showInfo {
            model.showInfo = false
        } else {
            return false
        }
        return true
    }

    private func addCurrentToBoard() {
        guard let url = model.current?.url else { return }
        addToBoard([url])
    }

    // MARK: - Actions

    @objc func nextImage(_ sender: Any?) { model.next() }
    @objc func previousImage(_ sender: Any?) { model.previous() }
    @objc func firstImage(_ sender: Any?) { model.first() }
    @objc func lastImage(_ sender: Any?) { model.last() }
    @objc func zoomIn(_ sender: Any?) { model.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { model.zoomOut() }
    @objc func zoomToActualSize(_ sender: Any?) { model.zoomToActualSize() }
    @objc func zoomToFit(_ sender: Any?) { model.zoomToFit() }
    @objc func rotateLeft(_ sender: Any?) { model.rotate(by: -1) }
    @objc func rotateRight(_ sender: Any?) { model.rotate(by: 1) }
    @objc func toggleGrid(_ sender: Any?) { model.toggleGrid() }
    @objc func toggleInfo(_ sender: Any?) { model.showInfo.toggle() }
    @objc func toggleThumbnails(_ sender: Any?) { model.showThumbnails.toggle() }
    @objc func toggleAmbientBackground(_ sender: Any?) { model.ambientBackground.toggle() }
    @objc func showShortcuts(_ sender: Any?) { model.showShortcuts.toggle() }
    @objc func togglePlayback(_ sender: Any?) { model.togglePlayback() }
    @objc func toggleLoop(_ sender: Any?) { model.toggleLoop() }
    /// The tag of the menu item is the number of seconds.
    @objc func jumpBack(_ sender: NSMenuItem) { model.seekVideo(by: -Double(sender.tag)) }
    @objc func jumpForward(_ sender: NSMenuItem) { model.seekVideo(by: Double(sender.tag)) }
    @objc func previousFrame(_ sender: Any?) { model.stepVideoFrame(by: -1) }
    @objc func nextFrame(_ sender: Any?) { model.stepVideoFrame(by: 1) }
    @objc func slower(_ sender: Any?) { model.changeVideoSpeed(by: -1) }
    @objc func faster(_ sender: Any?) { model.changeVideoSpeed(by: 1) }
    @objc func normalSpeed(_ sender: Any?) { model.resetVideoSpeed() }
    @objc func volumeUp(_ sender: Any?) { model.changeVolume(by: 0.1) }
    @objc func volumeDown(_ sender: Any?) { model.changeVolume(by: -0.1) }
    @objc func toggleMute(_ sender: Any?) { model.toggleMute() }
    @objc func copyFrame(_ sender: Any?) { model.copyCurrentFrame() }
    @objc func revealInFinder(_ sender: Any?) { model.revealCurrentInFinder() }
    @objc func copy(_ sender: Any?) { model.copyCurrent() }
    @objc func copyPath(_ sender: Any?) { model.copyCurrentPath() }

    @objc func moveToTrash(_ sender: Any?) {
        model.moveCurrentToTrash(undoManager: window?.undoManager)
    }

    @objc func setSortKey(_ sender: NSMenuItem) {
        if let key = SortKey(rawValue: sender.tag) { model.sortKey = key }
    }

    @objc func setSortOrder(_ sender: NSMenuItem) {
        model.sortAscending = sender.tag == 1
    }

    // MARK: Workspace actions

    /// The tag of the menu item: 0 all types, 1 images, 2 videos, 3 documents.
    @objc func setFilterKind(_ sender: NSMenuItem) {
        model.filter = TypeFilter(kind: Self.filterKinds[sender.tag])
    }

    @objc func toggleFormat(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? String else { return }
        model.toggleFormat(format)
    }

    @objc func clearFilter(_ sender: Any?) { model.filter = TypeFilter() }
    @objc func toggleStar(_ sender: Any?) { model.toggleStar() }
    @objc func addCurrentFileToBoard(_ sender: Any?) { addCurrentToBoard() }

    /// The tag of the menu item is the position of the tag in the quick tags.
    @objc func toggleTag(_ sender: NSMenuItem) {
        guard FinderTag.quickTags.indices.contains(sender.tag) else { return }
        model.toggleTag(FinderTag.quickTags[sender.tag])
    }

    @objc func showQuickSearch(_ sender: Any?) {
        let search = tab.quickSearch
        search.isVisible ? search.hide() : search.show(.open)
    }

    @objc func addFilesToBoard(_ sender: Any?) { tab.quickSearch.show(.addToBoard) }

    @objc func addNote(_ sender: Any?) {
        guard let id = tab.boardID, let board = Workspace.shared.board(id) else { return }
        let count = CGFloat(board.items.count)
        let note = Workspace.shared.addNote(to: id, at: CGPoint(x: 60 + count.truncatingRemainder(dividingBy: 8) * 24, y: 60))
        tab.boardSelection = note
        tab.focusedNote = note
    }

    @objc func arrangeBoard(_ sender: Any?) {
        guard let id = tab.boardID else { return }
        let width = tab.boardViewportWidth
        withAnimation(.smooth(duration: 0.35)) {
            Workspace.shared.arrange(id, width: width)
        }
    }

    @objc func newBoard(_ sender: Any?) {
        let board = Workspace.shared.newBoard()
        present(.board(board.id), placement: isBlank ? .current : .newTab)
    }

    @objc func addCurrentFolderToWorkspace(_ sender: Any?) {
        guard let folder = folderOutsideWorkspace else { return }
        Workspace.shared.addFolders([folder])
        model.showToast("Added to the workspace", symbol: "folder.badge.plus")
    }

    @objc override func newWindowForTab(_ sender: Any?) {
        appDelegate?.newTab(next: self)
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc func closeWindowAndTabs(_ sender: Any?) {
        guard let window else { return }
        for tabWindow in window.tabbedWindows ?? [window] { tabWindow.close() }
    }

    /// The split view controller toggles the sidebar when it is in the responder chain. This covers the other cases.
    @objc func toggleSidebar(_ sender: Any?) {
        splitController.toggleSidebar(sender)
    }

    private static let filterKinds: [ItemKind?] = [nil, .image, .video, .document]

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasImage = model.current != nil
        let canZoom = model.showsImage || model.showsPDF
        switch item.action {
        case #selector(nextImage(_:)), #selector(lastImage(_:)):
            return model.index < model.items.count - 1
        case #selector(previousImage(_:)), #selector(firstImage(_:)):
            return model.index > 0 && model.hasItems
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)):
            return canZoom || (hasImage && model.isGridMode)
        case #selector(zoomToActualSize(_:)), #selector(zoomToFit(_:)), #selector(rotateLeft(_:)), #selector(rotateRight(_:)):
            return canZoom
        case #selector(togglePlayback(_:)), #selector(jumpBack(_:)), #selector(jumpForward(_:)),
             #selector(previousFrame(_:)), #selector(nextFrame(_:)), #selector(slower(_:)), #selector(faster(_:)),
             #selector(volumeUp(_:)), #selector(volumeDown(_:)), #selector(copyFrame(_:)):
            return model.showsVideo
        case #selector(normalSpeed(_:)):
            item.state = model.video.player.defaultRate == 1 ? .on : .off
            return model.showsVideo
        case #selector(toggleMute(_:)):
            item.state = model.video.player.isMuted ? .on : .off
            return model.showsVideo
        case #selector(toggleLoop(_:)):
            item.state = model.video.isLooping ? .on : .off
            return true
        case #selector(toggleGrid(_:)):
            item.state = model.isGridMode ? .on : .off
            return model.hasItems
        case #selector(toggleInfo(_:)):
            item.state = model.showInfo ? .on : .off
            return tab.boardID == nil
        case #selector(toggleThumbnails(_:)):
            item.state = model.showThumbnails ? .on : .off
            return true
        case #selector(toggleAmbientBackground(_:)):
            item.state = model.ambientBackground ? .on : .off
            return true
        case #selector(revealInFinder(_:)), #selector(copy(_:)), #selector(copyPath(_:)), #selector(moveToTrash(_:)):
            return hasImage
        case #selector(setSortKey(_:)):
            item.state = item.tag == model.sortKey.rawValue ? .on : .off
            return true
        case #selector(setSortOrder(_:)):
            item.state = (item.tag == 1) == model.sortAscending ? .on : .off
            return true
        case #selector(setFilterKind(_:)):
            let kind = Self.filterKinds.indices.contains(item.tag) ? Self.filterKinds[item.tag] : nil
            item.state = model.filter.formats.isEmpty && model.filter.kind == kind ? .on : .off
            guard model.source != nil else { return false }
            return kind.map { (model.kindCounts[$0] ?? 0) > 0 } ?? true
        case #selector(toggleFormat(_:)):
            item.state = (item.representedObject as? String).map(model.filter.formats.contains) == true ? .on : .off
            return true
        case #selector(clearFilter(_:)):
            return model.filter.isActive
        case #selector(toggleStar(_:)):
            let starred = model.current.map { Workspace.shared.isStarred($0.url) } ?? false
            item.title = starred ? "Remove Star" : "Star"
            return hasImage
        case #selector(toggleTag(_:)):
            let tag = FinderTag.quickTags.indices.contains(item.tag) ? FinderTag.quickTags[item.tag] : nil
            item.state = model.current.flatMap { url in tag.map { Workspace.shared.hasTag($0.name, url.url) } } == true ? .on : .off
            return hasImage
        case #selector(addCurrentFileToBoard(_:)):
            return hasImage
        case #selector(addFilesToBoard(_:)), #selector(addNote(_:)), #selector(arrangeBoard(_:)):
            return tab.boardID != nil
        case #selector(addCurrentFolderToWorkspace(_:)):
            if let folder = folderOutsideWorkspace {
                item.title = "Add “\(FileManager.default.displayName(atPath: folder.path))” to Workspace"
                return true
            }
            item.title = "Add Current Folder to Workspace"
            return false
        case #selector(toggleSidebar(_:)):
            item.title = sidebarItem.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(closeWindowAndTabs(_:)):
            return (window?.tabbedWindows?.count ?? 1) > 1
        default:
            return true
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .rotate: model.showsImage || model.showsPDF
        case .trash: model.current != nil
        case .grid: model.hasItems
        case .filter: model.source != nil
        default: true
        }
    }

    // MARK: - File type menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === filterMenu else { return }
        menu.removeAllItems()
        let counts = model.kindCounts
        let kinds: [(String, Int, ItemKind?)] = [("All Types", 0, nil), ("Images", 1, .image), ("Videos", 2, .video), ("Documents", 3, .document)]
        for (title, tag, kind) in kinds {
            let count = kind.map { counts[$0] ?? 0 } ?? model.allItems.count
            let item = NSMenuItem(title: "\(title)  (\(count))", action: #selector(setFilterKind(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
            menu.addItem(item)
        }
        let formats = model.formatCounts
        guard !formats.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Formats"))
        for (format, count) in formats {
            let item = NSMenuItem(title: "\(format)  (\(count))", action: #selector(toggleFormat(_:)), keyEquivalent: "")
            item.representedObject = format
            item.target = self
            menu.addItem(item)
        }
    }

    // MARK: - Toolbar

    /// A board has its own toolbar buttons.
    private func configureToolbar() {
        let toolbar = tab.boardID == nil ? viewerToolbar : boardToolbar
        if window?.toolbar !== toolbar { window?.toolbar = toolbar }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let leading: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
        if toolbar === boardToolbar {
            return leading + [.addFiles, .addNote, .arrange, .space, .search]
        }
        return leading + [.rotate, .trash, .share, .space, .sort, .filter, .grid, .info, .space, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space, .rotate, .trash, .share, .sort, .filter,
         .grid, .info, .search, .addFiles, .addNote, .arrange]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .rotate:
            return button(identifier, "Rotate", "rotate.right", #selector(rotateRight(_:)))
        case .trash:
            return button(identifier, "Move to Trash", "trash", #selector(moveToTrash(_:)))
        case .grid:
            return button(identifier, "Grid", "square.grid.2x2", #selector(toggleGrid(_:)))
        case .info:
            return button(identifier, "Info", "info.circle", #selector(toggleInfo(_:)))
        case .search:
            return button(identifier, "Quick Search (⌘K)", "magnifyingglass", #selector(showQuickSearch(_:)))
        case .addFiles:
            return button(identifier, "Add Files", "plus.rectangle.on.rectangle", #selector(addFilesToBoard(_:)))
        case .addNote:
            return button(identifier, "Add Note", "note.text.badge.plus", #selector(addNote(_:)))
        case .arrange:
            return button(identifier, "Arrange", "rectangle.3.group", #selector(arrangeBoard(_:)))
        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.label = "Share"
            item.toolTip = "Share"
            item.delegate = self
            return item
        case .sort:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Sort"
            item.toolTip = "Sort By"
            item.image = symbol("arrow.up.arrow.down", "Sort")
            item.menu = MainMenu.sortMenu()
            item.showsIndicator = false
            return item
        case .filter:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "File Types"
            item.toolTip = "Show only some file types"
            item.image = symbol(model.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                                "File Types")
            item.menu = filterMenu
            item.showsIndicator = false
            return item
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, _ label: String, _ symbolName: String,
                        _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = symbol(symbolName, label)
        item.action = action
        item.isBordered = true
        return item
    }

    private func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    nonisolated func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        MainActor.assumeIsolated {
            model.current.map { [$0.url] } ?? []
        }
    }

    // MARK: - Window delegate

    func windowWillClose(_ notification: Notification) {
        if let window, !window.styleMask.contains(.fullScreen) {
            Preferences.windowFrame = window.frame
        }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observations = []
        model.stopVideo()
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        appDelegate?.sessionDidChange()
    }

    func windowDidResize(_ notification: Notification) {
        updateTitlebarHeight()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let window, !window.styleMask.contains(.fullScreen) {
            Preferences.windowFrame = window.frame
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        // The image gets the whole screen. The sidebar comes back after full screen.
        isChangingFullScreen = true
        sidebarWasCollapsed = sidebarItem.isCollapsed
        sidebarItem.isCollapsed = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isChangingFullScreen = false
        model.isFullScreen = true
        updateTitlebarHeight()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isChangingFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        model.isFullScreen = false
        sidebarItem.isCollapsed = sidebarWasCollapsed
        isChangingFullScreen = false
        updateTitlebarHeight()
    }

    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = [])
        -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideMenuBar, .autoHideToolbar, .autoHideDock]
    }
}

#if DEBUG
extension ViewerWindowController {
    /// Development aid: presses a key in this window only, for example "down" or "shift+space".
    /// The key takes the same path as a real key: first the key handler, then the first responder.
    func simulateKey(_ name: String) {
        let keys: [String: (code: Int, character: Int)] = [
            "left": (kVK_LeftArrow, NSLeftArrowFunctionKey), "right": (kVK_RightArrow, NSRightArrowFunctionKey),
            "up": (kVK_UpArrow, NSUpArrowFunctionKey), "down": (kVK_DownArrow, NSDownArrowFunctionKey),
            "pageup": (kVK_PageUp, NSPageUpFunctionKey), "pagedown": (kVK_PageDown, NSPageDownFunctionKey),
            "home": (kVK_Home, NSHomeFunctionKey), "end": (kVK_End, NSEndFunctionKey), "space": (kVK_Space, 0x20),
            "return": (kVK_Return, 0x0D), "escape": (kVK_Escape, 0x1B), "delete": (kVK_Delete, 0x7F),
            "s": (kVK_ANSI_S, 0x73), "b": (kVK_ANSI_B, 0x62), "1": (kVK_ANSI_1, 0x31), "2": (kVK_ANSI_2, 0x32),
        ]
        let shift = name.hasPrefix("shift+")
        guard let window, let key = keys[shift ? String(name.dropFirst(6)) : name],
              let scalar = UnicodeScalar(key.character) else { return }
        let characters = String(Character(scalar))
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(key.code)
        ) else { return }
        if !handleKeyDown(event) { window.sendEvent(event) }
    }
}
#endif

/// Maps key events to ASCII characters. With a non-Latin input source (for example Korean),
/// the event gives a non-ASCII character, so the physical key position is used instead.
enum KeyboardLayout {
    private static let ansiKeys: [Int: Character] = [
        kVK_ANSI_G: "g", kVK_ANSI_I: "i", kVK_ANSI_T: "t", kVK_ANSI_F: "f", kVK_ANSI_Z: "z", kVK_ANSI_R: "r",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_Slash: "/",
        kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_S: "s", kVK_ANSI_B: "b",
        kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
    ]

    static func character(for event: NSEvent) -> Character? {
        if let characters = event.charactersIgnoringModifiers?.lowercased(),
           characters.count == 1, let character = characters.first, character.isASCII {
            return character
        }
        return ansiKeys[Int(event.keyCode)]
    }
}
