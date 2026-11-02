import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controllers: [ViewerWindowController] = []
    private var hasRestoredSession = false
    private var sessionTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tabs: ⌘T, the tab bar and the tab commands of the Window menu.
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = MainMenu.build()
        _ = Workspace.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreSessionIfNeeded()
        // Paths passed on the command line (useful during development).
        let paths = CommandLine.arguments.dropFirst().filter { FileManager.default.fileExists(atPath: $0) }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty {
            open(urls)
        } else if controllers.isEmpty {
            showEmptyWindow()
        }
        NSApp.activate()
        #if DEBUG
        applyDebugCommands()
        #endif
    }

    #if DEBUG
    /// Development aid: GLIMPSE_DEBUG="next,info" runs viewer commands after launch.
    /// It lets scripts put the window in a known state for screenshots. "wait" delays the next commands by 1 s.
    private func applyDebugCommands() {
        guard let commands = ProcessInfo.processInfo.environment["GLIMPSE_DEBUG"] else { return }
        var delay = 1.0
        for command in commands.split(separator: ",") {
            if command == "wait" {
                delay += 1
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let controller = self.frontController else { return }
                    let model = controller.model
                    let workspace = Workspace.shared
                    if command.hasPrefix("key:") {
                        controller.simulateKey(String(command.dropFirst(4)))
                        return
                    }
                    if command.hasPrefix("appkey:"), let window = controller.window,
                       let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: String(command.dropFirst(7)),
                                                    charactersIgnoringModifiers: String(command.dropFirst(7)),
                                                    isARepeat: false, keyCode: 1) {
                        // The event takes the full path of a real key: the monitors, the menus and the first responder.
                        NSApp.postEvent(event, atStart: false)
                        return
                    }
                    if command == "responder" {
                        NSLog("GLIMPSE fka=%d responder=%@ controlFocus=%d", NSApp.isFullKeyboardAccessEnabled ? 1 : 0,
                              String(describing: controller.window?.firstResponder), model.controlHasKeyboardFocus ? 1 : 0)
                        return
                    }
                    if command == "log" {
                        NSLog("GLIMPSE query=%@ stars=%d", controller.tab.quickSearch.query, workspace.stars.count)
                        return
                    }
                    if command.hasPrefix("query:") {
                        controller.tab.quickSearch.query = String(command.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
                        return
                    }
                    if command.hasPrefix("filter:") {
                        let kinds: [String: ItemKind] = ["image": .image, "video": .video, "document": .document]
                        model.filter = TypeFilter(kind: kinds[String(command.dropFirst(7))])
                        return
                    }
                    // "moveto:1" drops the current file on the second workspace folder in the sidebar.
                    if command.hasPrefix("moveto:"), let url = model.current?.url {
                        let index = Int(command.dropFirst(7)) ?? 0
                        if workspace.folders.indices.contains(index) {
                            model.transfer([url], into: workspace.folders[index].url,
                                           undoManager: controller.window?.undoManager)
                        }
                        return
                    }
                    // "owndrop:/path/file.png" drops a file from another Glimpse tab on this tab.
                    if command.hasPrefix("owndrop:") {
                        let url = URL(fileURLWithPath: String(command.dropFirst(8)))
                        OutgoingDrag.begin([url])
                        _ = model.handleDrop([url])
                        return
                    }
                    if command == "undo" {
                        controller.window?.undoManager?.undo()
                        return
                    }
                    if command.hasPrefix("folder:") {
                        let index = Int(command.dropFirst(7)) ?? 0
                        if workspace.folders.indices.contains(index) {
                            controller.openSidebarItem(.folder(workspace.folders[index].url), inNewTab: false)
                        }
                        return
                    }
                    switch command {
                    case "next": model.next()
                    case "info": model.showInfo = true
                    case "grid": model.setGridMode(true)
                    case "shortcuts": model.showShortcuts = true
                    case "zoom": model.toggleZoom()
                    case "rotate": model.rotate(by: 1)
                    case "play": model.togglePlayback()
                    case "forward": model.seekVideo(by: 10)
                    case "faster": model.changeVideoSpeed(by: 1)
                    case "volume": model.changeVolume(by: -0.1)
                    case "loop": model.toggleLoop()
                    case "search": controller.showQuickSearch(nil)
                    case "newtab": self.newTab(next: controller)
                    case "starred": controller.openSidebarItem(.smart(.starred), inNewTab: false)
                    case "board":
                        if let id = workspace.targetBoardID { controller.showBoard(id) }
                    case "arrange": controller.arrangeBoard(nil)
                    case "note": controller.addNote(nil)
                    case "sidebar": controller.toggleSidebar(nil)
                    default: break
                    }
                }
            }
        }
    }
    #endif

    func application(_ application: NSApplication, open urls: [URL]) {
        restoreSessionIfNeeded()
        open(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // After the last window closes there is nothing to save. The session from before stays.
        if !controllers.isEmpty { Workspace.shared.saveSession(currentSession()) }
        Workspace.shared.saveNow()
        // Closing the videos records where long videos stopped.
        controllers.forEach { $0.model.stopVideo() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEmptyWindow() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Opening

    func open(_ urls: [URL]) {
        let requests = OpenRequest.make(from: urls)
        guard !requests.isEmpty else {
            NSSound.beep()
            return
        }
        requests.forEach(route)
    }

    /// Files and folders from Finder, the Dock or the open panel. A folder that a tab shows opens in that tab.
    /// Anything else opens in an empty tab or in a new tab.
    private func route(_ request: OpenRequest) {
        if case .folder(let folder, let selection) = request,
           let existing = controllers.first(where: { $0.shows(.request(.folder(folder, selecting: nil))) }) {
            if let selection { existing.model.show(selection) }
            existing.showWindow(nil)
            return
        }
        let controller = controllers.first(where: \.isBlank) ?? makeTab(near: frontController)
        controller.open(request)
        controller.showWindow(nil)
    }

    /// Shows a target from the sidebar or from Quick Search. Returns the tab that shows it.
    @discardableResult
    func present(_ target: TabTarget, from origin: ViewerWindowController, placement: TabPlacement) -> ViewerWindowController {
        let shown: ViewerWindowController
        if placement == .reuseOrCurrent, let existing = controllers.first(where: { $0.shows(target) }) {
            shown = existing
        } else if placement == .newTab {
            shown = makeTab(near: origin)
            shown.apply(target)
        } else {
            shown = origin
            if !origin.shows(target) { origin.apply(target) }
        }
        // A tab that shows the folder already selects the file. It does not scan the folder again.
        if shown.shows(target), case .request(.folder(_, let selection?)) = target {
            shown.model.show(selection)
        }
        shown.showWindow(nil)
        return shown
    }

    /// ⌘T and the + button of the tab bar. The new tab starts with Quick Search.
    func newTab(next origin: ViewerWindowController?) {
        let controller = makeTab(near: origin)
        controller.showWindow(nil)
        controller.tab.quickSearch.show(.newTab)
    }

    /// The tabs that show a deleted board become empty.
    func closeBoardTabs(_ id: UUID) {
        for controller in controllers where controller.tab.boardID == id {
            controller.showNothing()
        }
    }

    /// The selected tab of the front window. It works also while Glimpse is in the background.
    private var frontController: ViewerWindowController? {
        (NSApp.keyWindow?.windowController as? ViewerWindowController)
            ?? (NSApp.mainWindow?.windowController as? ViewerWindowController)
            ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? ViewerWindowController }.first
            ?? controllers.last
    }

    private func showEmptyWindow() {
        let controller = controllers.first(where: \.isBlank) ?? makeController()
        controller.showWindow(nil)
    }

    /// A new tab in the window of `origin`, or a new window if no window is open.
    private func makeTab(near origin: ViewerWindowController?) -> ViewerWindowController {
        let host = (origin ?? frontController)?.window
        let controller = makeController(cascadingFrom: host)
        if let host, host.isVisible, let window = controller.window {
            host.addTabbedWindow(window, ordered: .above)
        }
        return controller
    }

    private func makeController(cascadingFrom previous: NSWindow? = nil, frame: NSRect? = nil) -> ViewerWindowController {
        let controller = ViewerWindowController(cascadingFrom: previous ?? controllers.last?.window, frame: frame)
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
            self?.sessionDidChange()
        }
        controllers.append(controller)
        return controller
    }

    // MARK: - Session

    /// Records the open tabs a moment after they change, so that they open again at the next launch.
    func sessionDidChange() {
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, !self.controllers.isEmpty else { return }
            Workspace.shared.saveSession(self.currentSession())
        }
    }

    private func currentSession() -> [SavedWindow] {
        var seen = Set<ObjectIdentifier>()
        var windows: [SavedWindow] = []
        let viewerWindows = NSApp.orderedWindows.filter { $0.windowController is ViewerWindowController }
        for window in viewerWindows where !seen.contains(ObjectIdentifier(window)) {
            let group = window.tabbedWindows ?? [window]
            group.forEach { seen.insert(ObjectIdentifier($0)) }
            let selectedWindow = window.tabGroup?.selectedWindow ?? window
            var tabs: [SavedTab] = []
            var selected = 0
            for tabWindow in group {
                guard let saved = (tabWindow.windowController as? ViewerWindowController)?.savedTab() else { continue }
                if tabWindow === selectedWindow { selected = tabs.count }
                tabs.append(saved)
            }
            guard !tabs.isEmpty else { continue }
            windows.append(SavedWindow(tabs: tabs, selected: selected, frame: NSStringFromRect(window.frame)))
        }
        return windows
    }

    private func restoreSessionIfNeeded() {
        guard !hasRestoredSession else { return }
        hasRestoredSession = true
        let workspace = Workspace.shared
        guard workspace.reopenAtLaunch else { return }
        workspace.savedSession.forEach(restore)
    }

    private func restore(_ saved: SavedWindow) {
        var restored: [ViewerWindowController] = []
        var selected: ViewerWindowController?
        for (index, tab) in saved.tabs.enumerated() where Self.canRestore(tab) {
            let frame = restored.isEmpty ? saved.frame.map(NSRectFromString) : nil
            let controller = makeController(frame: frame)
            if let last = restored.last?.window, let window = controller.window {
                last.addTabbedWindow(window, ordered: .above)
            } else {
                controller.showWindow(nil)
            }
            controller.restore(tab)
            restored.append(controller)
            if index <= saved.selected { selected = controller }
        }
        (selected ?? restored.first)?.showWindow(nil)
    }

    private static func canRestore(_ tab: SavedTab) -> Bool {
        switch tab.kind {
        case .folder: tab.path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        case .files: tab.paths?.contains { FileManager.default.fileExists(atPath: $0) } ?? false
        case .board: tab.board.flatMap { Workspace.shared.board($0) } != nil
        case .starred, .tag: true
        }
    }

    // MARK: - Actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .folder] + VideoDecoder.playableTypes + DocumentDecoder.types
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose an image, a video, a document or a folder."
        panel.prompt = "Open"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { self?.open(urls) }
        }
    }

    @objc func addFolderToWorkspace(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to add to the workspace. The files stay where they are."
        panel.prompt = "Add"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { self?.addFolders(urls) }
        }
    }

    /// Adds folders to the workspace. An empty tab shows the first new folder.
    private func addFolders(_ urls: [URL]) {
        let added = Workspace.shared.addFolders(urls)
        guard let first = added.first else { return }
        if let controller = frontController, controller.isBlank {
            controller.open(.folder(first, selecting: nil))
        }
    }

    @objc func toggleReopenAtLaunch(_ sender: Any?) {
        Workspace.shared.reopenAtLaunch.toggle()
    }

    @objc func makeDefaultViewer(_ sender: Any?) {
        guard Bundle.main.bundleIdentifier != nil else {
            let alert = NSAlert()
            alert.messageText = "Run Glimpse from its app bundle"
            alert.informativeText = "Build the app with “make app” and open build/Glimpse.app, then try again."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Make Glimpse your default image viewer?"
        alert.informativeText = "JPEG, PNG, HEIC, GIF, WebP, TIFF, BMP and AVIF files will open in Glimpse when you double-click them in Finder."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let identifiers = ["public.jpeg", "public.png", "public.heic", "public.heif", "com.compuserve.gif",
                           "org.webmproject.webp", "public.tiff", "com.microsoft.bmp", "public.avif"]
        let types = identifiers.compactMap { UTType($0) }
        let appURL = Bundle.main.bundleURL
        Task {
            var failures: [String] = []
            for type in types {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
                } catch {
                    failures.append(type.preferredFilenameExtension ?? type.identifier)
                }
            }
            let done = NSAlert()
            if failures.isEmpty {
                done.messageText = "Glimpse is now your default image viewer."
            } else {
                done.messageText = "Some file types were not changed."
                done.informativeText = "Not changed: " + failures.joined(separator: ", ")
            }
            done.runModal()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleReopenAtLaunch(_:)) {
            menuItem.state = Workspace.shared.reopenAtLaunch ? .on : .off
        }
        return true
    }
}
