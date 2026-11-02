import AppKit
import Carbon.HIToolbox
import SwiftUI

private extension NSToolbarItem.Identifier {
    static let rotate = Self("rotate")
    static let trash = Self("trash")
    static let share = Self("share")
    static let sort = Self("sort")
    static let grid = Self("grid")
    static let info = Self("info")
}

@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSToolbarItemValidation, NSSharingServicePickerToolbarItemDelegate {
    let model = ViewerModel()
    var onClose: ((ViewerWindowController) -> Void)?

    private var monitors: [Any] = []

    init(cascadingFrom previous: NSWindow?) {
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
        window.tabbingMode = .disallowed
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 560, height: 400)
        super.init(window: window)

        window.delegate = self
        let toolbar = NSToolbar(identifier: "Glimpse.Viewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let hostingView = NSHostingView(rootView: RootView(model: model))
        hostingView.sizingOptions = []
        // The window controller owns the title, the subtitle and the toolbar. Do not let SwiftUI change them.
        hostingView.sceneBridgingOptions = []
        window.contentView = hostingView

        placeWindow(window, after: previous)
        installEventMonitors()
        observeModel()
        updateTitlebarHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func placeWindow(_ window: NSWindow, after previous: NSWindow?) {
        if let previous {
            window.setFrame(previous.frame, display: false)
            let topLeft = NSPoint(x: previous.frame.minX, y: previous.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        } else if let saved = Preferences.windowFrame,
                  NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            window.setFrame(saved, display: false)
        } else if let screen = NSScreen.main?.visibleFrame {
            let size = NSSize(width: (screen.width * 0.72).rounded(), height: (screen.height * 0.8).rounded())
            window.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                   width: size.width, height: size.height), display: false)
        }
    }

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
        window.title = model.windowTitle
        window.subtitle = model.windowSubtitle
        let isGrid = model.isGridMode
        let showInfo = model.showInfo
        for item in window.toolbar?.items ?? [] {
            switch item.itemIdentifier {
            case .grid:
                item.image = symbol(isGrid ? "square.grid.2x2.fill" : "square.grid.2x2", "Grid")
            case .info:
                item.image = symbol(showInfo ? "info.circle.fill" : "info.circle", "Info")
            default:
                break
            }
        }
    }

    private func updateTitlebarHeight() {
        guard let window else { return }
        let height = window.frame.height - window.contentLayoutRect.height
        if abs(model.titlebarHeight - height) > 0.5 { model.titlebarHeight = max(0, height) }
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
                guard let self, window === self.window, let content = self.window?.contentView else { return }
                let point = content.convert(location, from: nil)
                let topLeft = CGPoint(x: point.x, y: content.bounds.height - point.y)
                self.model.pointerMoved(to: topLeft, in: content.bounds.size)
            }
            return event
        }
        monitors = [keyMonitor, mouseMonitor].compactMap { $0 }
    }

    /// Single keys without ⌘. Commands with ⌘ go through the menus.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let shift = flags.contains(.shift)

        switch Int(event.keyCode) {
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
            } else {
                shift ? model.previous() : model.next()
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard model.isGridMode, model.hasItems else { return false }
            model.openViewer(at: model.index)
        case kVK_Escape:
            return handleEscape()
        case kVK_ANSI_KeypadPlus: model.zoomIn()
        case kVK_ANSI_KeypadMinus: model.zoomOut()
        default:
            return handleCharacterKey(event, shift: shift)
        }
        return true
    }

    private func handleCharacterKey(_ event: NSEvent, shift: Bool) -> Bool {
        switch KeyboardLayout.character(for: event) {
        case "g": model.toggleGrid()
        case "i": model.showInfo.toggle()
        case "t": model.showThumbnails.toggle()
        case "f": window?.toggleFullScreen(nil)
        case "z": model.toggleZoom()
        case "r": model.rotate(by: shift ? -1 : 1)
        case "=", "+": model.zoomIn()
        case "-", "_": model.zoomOut()
        case "?", "/": model.showShortcuts.toggle()
        default: return false
        }
        return true
    }

    private func handleEscape() -> Bool {
        if model.showShortcuts {
            model.showShortcuts = false
        } else if let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else if model.isGridMode, model.current != nil, model.canvasContent != nil {
            model.setGridMode(false)
        } else if model.showInfo {
            model.showInfo = false
        } else {
            return false
        }
        return true
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasImage = model.current != nil
        let inViewer = hasImage && !model.isGridMode
        switch item.action {
        case #selector(nextImage(_:)), #selector(lastImage(_:)):
            return model.index < model.items.count - 1
        case #selector(previousImage(_:)), #selector(firstImage(_:)):
            return model.index > 0 && model.hasItems
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)):
            return hasImage
        case #selector(zoomToActualSize(_:)), #selector(zoomToFit(_:)), #selector(rotateLeft(_:)), #selector(rotateRight(_:)):
            return inViewer
        case #selector(toggleGrid(_:)):
            item.state = model.isGridMode ? .on : .off
            return model.hasItems
        case #selector(toggleInfo(_:)):
            item.state = model.showInfo ? .on : .off
            return true
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
        default:
            return true
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .rotate: model.current != nil && !model.isGridMode
        case .trash: model.current != nil
        case .grid: model.hasItems
        default: true
        }
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .rotate, .trash, .space, .share, .sort, .space, .grid, .info]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
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
        onClose?(self)
    }

    func windowDidResize(_ notification: Notification) {
        updateTitlebarHeight()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let window, !window.styleMask.contains(.fullScreen) {
            Preferences.windowFrame = window.frame
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        model.isFullScreen = true
        updateTitlebarHeight()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        model.isFullScreen = false
        updateTitlebarHeight()
    }

    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = [])
        -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideMenuBar, .autoHideToolbar, .autoHideDock]
    }
}

/// Maps key events to ASCII characters. With a non-Latin input source (for example Korean),
/// the event gives a non-ASCII character, so the physical key position is used instead.
enum KeyboardLayout {
    private static let ansiKeys: [Int: Character] = [
        kVK_ANSI_G: "g", kVK_ANSI_I: "i", kVK_ANSI_T: "t", kVK_ANSI_F: "f", kVK_ANSI_Z: "z", kVK_ANSI_R: "r",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_Slash: "/",
    ]

    static func character(for event: NSEvent) -> Character? {
        if let characters = event.charactersIgnoringModifiers?.lowercased(),
           characters.count == 1, let character = characters.first, character.isASCII {
            return character
        }
        return ansiKeys[Int(event.keyCode)]
    }
}
