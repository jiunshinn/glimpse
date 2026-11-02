import AppKit
import Observation

enum Layout {
    static let filmstripHeight: CGFloat = 64
    static let filmstripBottomMargin: CGFloat = 14
    static let filmstripReserved: CGFloat = filmstripHeight + filmstripBottomMargin + 10
    static let infoPanelWidth: CGFloat = 300
    static let panelMargin: CGFloat = 12
    static let edgeHoverWidth: CGFloat = 150
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let symbol: String?
}

enum HoverEdge {
    case leading, trailing
}

/// The state of one viewer window.
@MainActor
@Observable
final class ViewerModel {
    // MARK: Images

    private(set) var source: ImageSource?
    private(set) var items: [ImageItem] = []
    private(set) var index = 0
    private(set) var isScanning = false
    /// True from opening a folder until its first scan ends.
    private(set) var awaitsFirstScan = false

    // MARK: Displayed image

    private(set) var canvasContent: CanvasContent?
    private(set) var ambientImage: CGImage?
    private(set) var ambientKey: URL?
    private(set) var loadFailed = false
    private(set) var info: ImageInfo?
    private(set) var rotation = 0

    // MARK: Presentation

    private(set) var isGridMode = false
    var showInfo = false {
        didSet { if showInfo { loadInfo() } }
    }
    var showThumbnails = Preferences.showThumbnails {
        didSet { Preferences.showThumbnails = showThumbnails }
    }
    var ambientBackground = Preferences.ambientBackground {
        didSet { Preferences.ambientBackground = ambientBackground }
    }
    var sortKey = Preferences.sortKey {
        didSet { Preferences.sortKey = sortKey; resort() }
    }
    var sortAscending = Preferences.sortAscending {
        didSet { Preferences.sortAscending = sortAscending; resort() }
    }
    var gridTileSize = Preferences.gridTileSize {
        didSet { Preferences.gridTileSize = gridTileSize }
    }
    var gridColumns = 1
    var showShortcuts = false
    var isFullScreen = false {
        didSet { revealChrome() }
    }
    var titlebarHeight: CGFloat = 52
    var pointerOverChrome = false {
        didSet { if pointerOverChrome { revealChrome() } }
    }
    private(set) var chromeHidden = false
    private(set) var hoverEdge: HoverEdge?
    private(set) var toast: Toast?

    // MARK: Private state

    @ObservationIgnored weak var canvas: ImageCanvasView?
    @ObservationIgnored private let pipeline = ImagePipeline.shared
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var rotateTask: Task<Void, Never>?
    @ObservationIgnored private var infoTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var chromeTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var direction = 1
    /// The unrotated image that the canvas shows (a thumbnail or the full image).
    @ObservationIgnored private var base: (url: URL, image: CGImage, animated: NSImage?, pixelSize: CGSize)?

    // MARK: - Derived state

    var current: ImageItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var hasItems: Bool { !items.isEmpty }

    /// True for a new window that shows nothing yet.
    var isBlank: Bool { source == nil }

    var chromeVisible: Bool { !(isFullScreen && chromeHidden) }

    var filmstripVisible: Bool {
        showThumbnails && items.count > 1 && !isGridMode && chromeVisible
    }

    var topInset: CGFloat { isFullScreen ? 0 : titlebarHeight }

    var canvasInsets: NSEdgeInsets {
        // Keep the space during the first scan, so the image does not shrink when the filmstrip appears.
        let expectsFilmstrip = items.count > 1 || awaitsFirstScan
        let bottom = !isFullScreen && showThumbnails && expectsFilmstrip ? Layout.filmstripReserved : 0
        let right = showInfo ? Layout.infoPanelWidth + Layout.panelMargin * 2 : 0
        return NSEdgeInsets(top: topInset, left: 0, bottom: bottom, right: right)
    }

    var collectionName: String {
        switch source {
        case .folder(let url): url.lastPathComponent
        case .files: "Selected Images"
        case nil: "Glimpse"
        }
    }

    var windowTitle: String {
        if isGridMode || current == nil { return collectionName }
        return current?.name ?? collectionName
    }

    var windowSubtitle: String {
        guard hasItems else { return isScanning ? "Loading…" : "" }
        if isGridMode { return items.count == 1 ? "1 image" : "\(items.count) images" }
        return "\(index + 1) of \(items.count)"
    }

    // MARK: - Opening

    func open(_ request: OpenRequest) {
        scanTask?.cancel()
        loadTask?.cancel()
        watcher = nil
        rotation = 0
        loadFailed = false
        info = nil
        showShortcuts = false
        awaitsFirstScan = true

        switch request {
        case .folder(let folder, let selection):
            source = .folder(folder)
            watcher = FolderWatcher(folder: folder) { [weak self] in
                MainActor.assumeIsolated { self?.reload(selecting: nil) }
            }
            if let selection, let item = FolderScanner.item(for: selection) {
                // Show the chosen image at once. The rest of the folder arrives after the scan.
                items = [item]
                index = 0
                isGridMode = false
                clearCanvas()
                loadCurrent()
                NSDocumentController.shared.noteNewRecentDocumentURL(selection)
            } else {
                items = []
                index = 0
                isGridMode = true
                clearCanvas()
                NSDocumentController.shared.noteNewRecentDocumentURL(folder)
            }
            reload(selecting: selection)
        case .files(let urls):
            source = .files(urls)
            items = []
            index = 0
            isGridMode = false
            clearCanvas()
            reload(selecting: nil)
        }
    }

    func handleDrop(_ urls: [URL]) -> Bool {
        guard let request = OpenRequest.make(from: urls).first else { return false }
        open(request)
        return true
    }

    /// Scans the source again and keeps the current image selected if it still exists.
    func reload(selecting url: URL?) {
        guard let source else { return }
        isScanning = true
        let key = sortKey
        let ascending = sortAscending
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                FolderScanner.scan(source, sortedBy: key, ascending: ascending)
            }.value
            guard let self, !Task.isCancelled, self.source == source else { return }
            self.apply(scanned, selecting: url)
        }
    }

    private func apply(_ scanned: [ImageItem]?, selecting url: URL?) {
        isScanning = false
        awaitsFirstScan = false
        guard let scanned else {
            if hasItems { showToast("Glimpse can’t read this folder", symbol: "lock") }
            return
        }
        let previous = current
        let target = url ?? previous?.url
        let oldDates = Dictionary(items.map { ($0.url, $0.modified) }, uniquingKeysWith: { first, _ in first })
        for item in scanned where oldDates[item.url].map({ $0 != item.modified }) ?? false {
            pipeline.invalidate(item.url)
        }
        items = scanned
        if let target, let found = scanned.firstIndex(where: { $0.url.isSameFile(as: target) }) {
            index = found
        } else {
            index = min(index, max(scanned.count - 1, 0))
        }
        guard hasItems else {
            clearCanvas()
            return
        }
        if current != previous || canvasContent == nil {
            rotation = 0
            if !isGridMode { loadCurrent() }
            if showInfo { loadInfo() }
        }
    }

    private func resort() {
        let selected = current?.url
        items = FolderScanner.sorted(items, by: sortKey, ascending: sortAscending)
        if let selected, let found = items.firstIndex(where: { $0.url == selected }) {
            index = found
        }
    }

    private func clearCanvas() {
        loadTask?.cancel()
        base = nil
        canvasContent = nil
        ambientImage = nil
        ambientKey = nil
        loadFailed = false
        info = nil
    }

    // MARK: - Navigation

    func go(to newIndex: Int) {
        guard items.indices.contains(newIndex), newIndex != index || canvasContent == nil else { return }
        direction = newIndex >= index ? 1 : -1
        index = newIndex
        rotation = 0
        if !isGridMode { loadCurrent() }
        if showInfo { loadInfo() }
    }

    func next() {
        if index + 1 < items.count {
            go(to: index + 1)
        } else if hasItems {
            showToast("Last image", symbol: "arrow.right.to.line")
        }
    }

    func previous() {
        if index > 0 {
            go(to: index - 1)
        } else if hasItems {
            showToast("First image", symbol: "arrow.left.to.line")
        }
    }

    func first() { go(to: 0) }
    func last() { go(to: items.count - 1) }

    /// Arrow keys: in the grid they move the selection; in the viewer they change the image.
    func moveSelection(by delta: Int, vertical: Bool) {
        guard hasItems else { return }
        if isGridMode {
            let step = vertical ? delta * max(gridColumns, 1) : delta
            let target = min(max(index + step, 0), items.count - 1)
            go(to: target)
        } else {
            delta > 0 ? next() : previous()
        }
    }

    func page(by delta: Int) {
        guard hasItems else { return }
        let step = isGridMode ? max(gridColumns, 1) * 4 : 10
        go(to: min(max(index + delta * step, 0), items.count - 1))
    }

    // MARK: - Grid

    func toggleGrid() {
        setGridMode(!isGridMode)
    }

    func setGridMode(_ enabled: Bool) {
        guard hasItems || !enabled else { return }
        isGridMode = enabled
        hoverEdge = nil
        if !enabled, canvasContent.map({ !$0.url.isSameFile(as: current?.url ?? $0.url) }) ?? true {
            loadCurrent()
        }
    }

    func openViewer(at newIndex: Int) {
        guard items.indices.contains(newIndex) else { return }
        if newIndex != index { rotation = 0 }
        index = newIndex
        setGridMode(false)
        if showInfo { loadInfo() }
    }

    // MARK: - Loading

    private func loadCurrent() {
        loadTask?.cancel()
        rotateTask?.cancel()
        guard let item = current else {
            clearCanvas()
            return
        }
        let url = item.url
        loadFailed = false

        if let full = pipeline.cachedImage(for: url) {
            show(full.cgImage, animated: full.animated, pixelSize: full.pixelSize, for: url)
        } else if let thumbnail = pipeline.cachedThumbnail(for: url) {
            show(thumbnail.image, animated: nil, pixelSize: thumbnail.fullPixelSize, for: url)
        }
        // Otherwise the previous image stays until the new one is ready. This avoids a blank flash.
        if let thumbnail = pipeline.cachedThumbnail(for: url) {
            setAmbient(thumbnail.image, for: url)
        }

        loadTask = Task { [weak self, pipeline] in
            async let full = pipeline.image(for: url)
            if let thumbnail = await pipeline.thumbnail(for: url) {
                guard let self, !Task.isCancelled, self.current?.url == url else { return }
                self.setAmbient(thumbnail.image, for: url)
                if self.base.map({ !$0.url.isSameFile(as: url) }) ?? true {
                    self.show(thumbnail.image, animated: nil, pixelSize: thumbnail.fullPixelSize, for: url)
                }
            }
            let decoded = await full
            guard let self, !Task.isCancelled, self.current?.url == url else { return }
            if let decoded {
                self.show(decoded.cgImage, animated: decoded.animated, pixelSize: decoded.pixelSize, for: url)
            } else {
                self.loadFailed = true
                self.base = nil
                self.canvasContent = nil
            }
        }
        prefetchNeighbors()
    }

    private func prefetchNeighbors() {
        guard let current else { return }
        let neighbors = [index + direction, index + 2 * direction, index - direction]
            .filter { items.indices.contains($0) }
            .map { items[$0].url }
        pipeline.cancelFullRequests(except: Set(neighbors + [current.url]))
        neighbors.forEach(pipeline.prefetch)
    }

    private func setAmbient(_ image: CGImage, for url: URL) {
        guard ambientKey != url else { return }
        ambientImage = image
        ambientKey = url
    }

    private func show(_ image: CGImage, animated: NSImage?, pixelSize: CGSize, for url: URL) {
        base = (url, image, animated, pixelSize)
        applyRotation()
    }

    private func applyRotation() {
        rotateTask?.cancel()
        guard let base else { return }
        let turns = rotation
        guard turns != 0 else {
            canvasContent = CanvasContent(url: base.url, image: base.image, animated: base.animated,
                                          pixelSize: base.pixelSize, rotation: 0)
            return
        }
        let size = turns % 2 == 0 ? base.pixelSize : CGSize(width: base.pixelSize.height, height: base.pixelSize.width)
        let image = base.image
        rotateTask = Task { [weak self] in
            let rotated = await Task.detached(priority: .userInitiated) {
                ImageDecoder.rotate(image, quarterTurns: turns)
            }.value
            guard let self, !Task.isCancelled, let rotated,
                  self.base?.url == base.url, self.rotation == turns else { return }
            self.canvasContent = CanvasContent(url: base.url, image: rotated, animated: nil,
                                               pixelSize: size, rotation: turns)
        }
    }

    private func loadInfo() {
        infoTask?.cancel()
        guard let url = current?.url else {
            info = nil
            return
        }
        if info.map({ !$0.url.isSameFile(as: url) }) ?? false { info = nil }
        infoTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { ImageMetadata.load(url) }.value
            guard let self, !Task.isCancelled, self.current?.url == url else { return }
            self.info = loaded
        }
    }

    // MARK: - Commands

    func rotate(by turns: Int) {
        guard !isGridMode, base != nil else { return }
        rotation = ((rotation + turns) % 4 + 4) % 4
        applyRotation()
    }

    func zoomIn() {
        if isGridMode {
            gridTileSize = min(gridTileSize + 40, 420)
        } else {
            canvas?.zoomIn()
        }
    }

    func zoomOut() {
        if isGridMode {
            gridTileSize = max(gridTileSize - 40, 90)
        } else {
            canvas?.zoomOut()
        }
    }

    func zoomToFit() {
        guard !isGridMode else { return }
        canvas?.zoomToFit(animated: true, userInitiated: true)
    }

    func zoomToActualSize() {
        guard !isGridMode else { return }
        canvas?.zoomToActualSize()
    }

    func toggleZoom() {
        guard !isGridMode else { return }
        canvas?.toggleZoom()
    }

    func copyCurrent() {
        guard let url = current?.url else { return }
        PasteboardWriter.copyImage(at: url)
        showToast("Copied", symbol: "doc.on.doc")
    }

    func copyCurrentPath() {
        guard let url = current?.url else { return }
        PasteboardWriter.copyPath(of: url)
        showToast("Path copied", symbol: "link")
    }

    func revealCurrentInFinder() {
        guard let url = current?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Trash

    func moveCurrentToTrash(undoManager: UndoManager?) {
        guard let item = current else { return }
        moveToTrash(item.url, undoManager: undoManager)
    }

    private func moveToTrash(_ url: URL, undoManager: UndoManager?) {
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        } catch {
            showToast("Couldn’t move to Trash", symbol: "exclamationmark.triangle")
            return
        }
        pipeline.invalidate(url)
        if case .files(let urls) = source {
            source = .files(urls.filter { !$0.isSameFile(as: url) })
        }
        if let removed = items.firstIndex(where: { $0.url.isSameFile(as: url) }) {
            let removedCurrent = removed == index
            items.remove(at: removed)
            if removed < index { index -= 1 }
            index = max(0, min(index, items.count - 1))
            if !hasItems {
                clearCanvas()
            } else if removedCurrent {
                // The next image moves into the current position.
                rotation = 0
                if !isGridMode { loadCurrent() }
                if showInfo { loadInfo() }
            }
        }
        showToast("Moved to Trash", symbol: "trash")

        guard let trashedURL = resultingURL as URL?, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restore(trashedURL, to: url, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Move to Trash")
    }

    private func restore(_ trashedURL: URL, to originalURL: URL, undoManager: UndoManager) {
        do {
            try FileManager.default.moveItem(at: trashedURL, to: originalURL)
        } catch {
            showToast("Couldn’t put back the file", symbol: "exclamationmark.triangle")
            return
        }
        if case .files(let urls) = source {
            source = .files(urls + [originalURL])
        }
        reload(selecting: originalURL)
        showToast("Put back", symbol: "arrow.uturn.backward")
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.moveToTrash(originalURL, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Move to Trash")
    }

    // MARK: - Toasts

    func showToast(_ message: String, symbol: String? = nil) {
        let toast = Toast(message: message, symbol: symbol)
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled, self.toast?.id == toast.id else { return }
            self.toast = nil
        }
    }

    // MARK: - Pointer and chrome

    /// `location` uses top-left coordinates in the window content.
    func pointerMoved(to location: CGPoint, in size: CGSize) {
        noteActivity()
        var edge: HoverEdge?
        if !isGridMode, items.count > 1, chromeVisible {
            let insets = canvasInsets
            let isInBand = location.y > insets.top && location.y < size.height - insets.bottom
            if isInBand && location.x < Layout.edgeHoverWidth {
                edge = .leading
            } else if isInBand && location.x > size.width - insets.right - Layout.edgeHoverWidth
                        && location.x < size.width - insets.right {
                edge = .trailing
            }
        }
        if edge != hoverEdge { hoverEdge = edge }
    }

    func pointerExited() {
        if hoverEdge != nil { hoverEdge = nil }
    }

    func noteActivity() {
        if chromeHidden { chromeHidden = false }
        // Mouse events arrive many times a second. Restart the timer only now and then.
        guard isFullScreen, Date().timeIntervalSince(lastActivity) > 0.25 else { return }
        lastActivity = Date()
        scheduleChromeHide()
    }

    private func revealChrome() {
        if chromeHidden { chromeHidden = false }
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeTask?.cancel()
        guard isFullScreen else { return }
        chromeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, self.isFullScreen, !self.pointerOverChrome, !self.isGridMode else { return }
            self.chromeHidden = true
            self.hoverEdge = nil
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

extension ViewerModel: ImageCanvasDelegate {
    func canvasDidZoom(percent: Int, isFit: Bool) {
        showToast(isFit ? "Fit  ·  \(percent)%" : "\(percent)%", symbol: "magnifyingglass")
    }

    func canvasRequestsNavigation(by delta: Int) {
        delta > 0 ? next() : previous()
    }

    func canvasPointerExited() {
        pointerExited()
    }
}
