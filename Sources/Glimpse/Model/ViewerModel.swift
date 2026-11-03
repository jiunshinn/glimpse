import AppKit
import AVFoundation
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
    /// Every file of the source.
    private(set) var allItems: [ImageItem] = []
    /// The files that the type filter shows. The viewer, the grid, the filmstrip and the arrow keys use these.
    private(set) var items: [ImageItem] = []
    private(set) var index = 0
    /// Shows only some kinds or formats of files. Each tab has its own filter.
    var filter = TypeFilter() {
        didSet { if filter != oldValue { applyFilter() } }
    }
    private(set) var isScanning = false
    /// True from opening a folder until its first scan ends.
    private(set) var awaitsFirstScan = false

    // MARK: Displayed image

    private(set) var canvasContent: CanvasContent?
    /// The display size of the current video. The video view stays hidden until it is known.
    private(set) var videoSize: CGSize?
    private(set) var ambientImage: CGImage?
    private(set) var ambientKey: URL?
    private(set) var loadFailed = false
    private(set) var info: ImageInfo?
    private(set) var rotation = 0

    // MARK: Displayed document

    /// The document that the viewer shows. Nil for an image or a video.
    private(set) var document: DocumentContent?
    /// The visible page of a PDF.
    private(set) var documentPage: DocumentPage?

    // MARK: Presentation

    private(set) var isGridMode = false
    var showInfo = false {
        didSet {
            guard showInfo else { return }
            loadInfo()
            describeCurrentIfNeeded()
        }
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
    /// The smallest and the largest grid tile.
    static let gridTileSizes: ClosedRange<Double> = 90...420
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

    // MARK: Accessibility

    /// What Vision found in an image. VoiceOver reads it, and the info panel shows it.
    private(set) var imageDescription: ImageDescription?

    // MARK: Private state

    let video = VideoController()
    @ObservationIgnored weak var canvas: ImageCanvasView?
    /// The PDF or Quick Look view of the current document.
    @ObservationIgnored weak var documentView: NSView?
    @ObservationIgnored private let pipeline = ImagePipeline.shared
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var rotateTask: Task<Void, Never>?
    @ObservationIgnored private var infoTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var chromeTask: Task<Void, Never>?
    @ObservationIgnored private var describeTask: Task<Void, Never>?
    @ObservationIgnored private var voiceOverObservation: NSKeyValueObservation?
    /// The controls in the viewer that have the keyboard focus now.
    @ObservationIgnored private var focusedControls: Set<UUID> = []
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var direction = 1
    @ObservationIgnored nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []
    /// The unrotated image that the canvas shows (a thumbnail or the full image).
    @ObservationIgnored private var base: (url: URL, image: CGImage, animated: NSImage?, pixelSize: CGSize)?

    init() {
        video.onFailure = { [weak self] in self?.loadFailed = true }
        let center = NotificationCenter.default
        workspaceObservers = [
            // A smart list collects files from all workspace folders. It changes when they change.
            center.addObserver(forName: .workspaceFilesDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, case .smart = self.source else { return }
                    self.reload(selecting: nil)
                }
            },
            // A pinned file moves to the start of the list. An unpinned file goes back to its sorted place.
            center.addObserver(forName: .pinnedFilesDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resort() }
            },
        ]
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            Task { @MainActor in self?.describeCurrentIfNeeded() }
        }
    }

    deinit {
        workspaceObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Derived state

    var current: ImageItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var hasItems: Bool { !items.isEmpty }

    /// True when the viewer plays a video instead of showing an image on the canvas.
    var showsVideo: Bool { !isGridMode && current?.isVideo == true }

    /// True when the viewer shows a document (PDF, Word, Excel and others) instead of an image.
    var showsDocument: Bool { !isGridMode && current?.isDocument == true }

    /// True when the viewer shows a PDF. Glimpse can zoom and rotate a PDF, but not other documents.
    var showsPDF: Bool { showsDocument && document?.isPDF == true }

    /// True for the image canvas, which zooms and rotates.
    var showsImage: Bool { !isGridMode && current?.kind == .image }

    /// True when the canvas, the player or the document view has something for the current item (it can still be loading).
    var hasViewerContent: Bool { canvasContent != nil || video.url != nil || document != nil }

    /// True for a new window that shows nothing yet.
    var isBlank: Bool { source == nil }

    /// True when the folder has files, but the type filter hides all of them.
    var filterHidesAll: Bool { items.isEmpty && !allItems.isEmpty }

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

    /// The player controls and the sheet tabs of a spreadsheet sit at the bottom.
    /// Keep them clear of the filmstrip in full screen too.
    var stageInsets: NSEdgeInsets {
        var insets = canvasInsets
        if isFullScreen && showThumbnails && items.count > 1 { insets.bottom = Layout.filmstripReserved }
        return insets
    }

    var collectionName: String {
        switch source {
        case .folder(let url): url.lastPathComponent
        case .files: "Selected Files"
        case .smart(let list): list.title
        case nil: "Glimpse"
        }
    }

    /// The folder that Pin Folder uses: the folder of the tab, or the folder of the current file in a list of files.
    var currentFolder: URL? {
        if case .folder(let url) = source { return url }
        return current?.url.deletingLastPathComponent()
    }

    var windowTitle: String {
        if isGridMode || current == nil { return collectionName }
        return current?.name ?? collectionName
    }

    var windowSubtitle: String {
        guard hasItems else {
            if isScanning { return "Loading…" }
            return filterHidesAll ? "No \(filter.title.lowercased())" : ""
        }
        var parts: [String] = []
        if isGridMode {
            parts.append(itemCountDescription)
        } else {
            parts.append("\(index + 1) of \(items.count)")
            if showsPDF, let page = documentPage, page.count > 1 {
                parts.append("Page \(page.index + 1) of \(page.count)")
            }
            if let url = current?.url {
                let workspace = Workspace.shared
                if workspace.isFilePinned(url) { parts.append("Pinned") }
                if workspace.isStarred(url) { parts.append("★") }
                let tags = workspace.tags(for: url).map(\.name)
                if !tags.isEmpty { parts.append(tags.joined(separator: ", ")) }
            }
        }
        if filter.isActive { parts.append(filter.title) }
        return parts.joined(separator: "  ·  ")
    }

    /// The number of files of each kind, before the filter.
    var kindCounts: [ItemKind: Int] {
        Dictionary(grouping: allItems, by: \.kind).mapValues(\.count)
    }

    /// The formats of the files and their numbers, for the kind that the filter shows.
    var formatCounts: [(format: String, count: Int)] {
        let shown = allItems.filter { filter.kind == nil || $0.kind == filter.kind }
        return Dictionary(grouping: shown, by: \.format)
            .map { (format: $0.key, count: $0.value.count) }
            .sorted { $0.format < $1.format }
    }

    private var itemCountDescription: String {
        let videos = items.lazy.filter(\.isVideo).count
        let documents = items.lazy.filter(\.isDocument).count
        let noun = videos == items.count ? "video" : documents == items.count ? "document"
            : videos + documents == 0 ? "image" : "item"
        return items.count == 1 ? "1 \(noun)" : "\(items.count) \(noun)s"
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
        allItems = []
        items = []

        switch request {
        case .folder(let folder, let selection):
            source = .folder(folder)
            watcher = FolderWatcher(folder: folder) { [weak self] in
                MainActor.assumeIsolated { self?.reload(selecting: nil) }
            }
            if let selection, let item = FolderScanner.item(for: selection) {
                // The chosen file must show, so a filter that hides it goes away.
                if !filter.allows(item) { filter = TypeFilter() }
                // Show the chosen image at once. The rest of the folder arrives after the scan.
                allItems = [item]
                items = [item]
                index = 0
                isGridMode = false
                clearCanvas()
                loadCurrent()
                NSDocumentController.shared.noteNewRecentDocumentURL(selection)
            } else {
                index = 0
                isGridMode = true
                clearCanvas()
                NSDocumentController.shared.noteNewRecentDocumentURL(folder)
            }
            reload(selecting: selection)
        case .files(let urls):
            source = .files(urls)
            index = 0
            isGridMode = false
            clearCanvas()
            reload(selecting: nil)
        case .smart(let list):
            source = .smart(list)
            index = 0
            isGridMode = true
            clearCanvas()
            reload(selecting: nil)
        }
    }

    /// Shows a file of the source. It opens the folder of the file if the source does not have it.
    func show(_ url: URL) {
        if let found = items.firstIndex(where: { $0.url.isSameFile(as: url) }) {
            openViewer(at: found)
        } else if allItems.contains(where: { $0.url.isSameFile(as: url) }) {
            filter = TypeFilter()
            show(url)
        } else {
            open(.folder(url.deletingLastPathComponent(), selecting: url))
        }
    }

    /// Empties the tab, for example before the tab shows a board.
    func close() {
        scanTask?.cancel()
        watcher = nil
        source = nil
        allItems = []
        items = []
        index = 0
        isScanning = false
        awaitsFirstScan = false
        isGridMode = false
        showInfo = false
        showShortcuts = false
        clearCanvas()
    }

    func handleDrop(_ urls: [URL]) -> Bool {
        // A file that is dragged from this tab and dropped on it again does not open again.
        if OutgoingDrag.carries(urls) {
            OutgoingDrag.end()
            if containsAll(urls) { return false }
            // A file from another tab moves into the folder of this tab.
            if let folder = dropFolder { return transfer(urls, into: folder) }
        }
        guard let request = OpenRequest.make(from: urls).first else { return false }
        open(request)
        return true
    }

    /// The folder that a file from another tab goes into. Nil when the tab does not show a folder.
    var dropFolder: URL? {
        guard case .folder(let folder) = source else { return nil }
        return folder
    }

    /// Moves the files into a folder, or copies them with ⌥ or to another disk. A toast tells the result.
    /// Returns true if a file moved or was copied.
    @discardableResult
    func transfer(_ urls: [URL], into folder: URL, undoManager: UndoManager? = nil) -> Bool {
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false }
        guard !files.isEmpty else { return false }
        // A phone photo that is still a preview: copy it when its full file is here.
        let library = DeviceLibrary.shared
        if files.contains(where: library.isPreview) {
            showToast("Getting the full files from the phone…", symbol: "arrow.down.circle")
            let undo = undoManager ?? canvas?.window?.undoManager
            Task { [weak self] in
                await library.ensureFull(files)
                self?.finishTransfer(files, into: folder, undoManager: undo)
            }
            return true
        }
        return finishTransfer(files, into: folder, undoManager: undoManager ?? canvas?.window?.undoManager)
    }

    @discardableResult
    private func finishTransfer(_ files: [URL], into folder: URL, undoManager: UndoManager?) -> Bool {
        let mode = FileMover.mode(for: files, into: folder)
        let result = FileMover.transfer(files, into: folder, mode: mode, undoManager: undoManager)
        let name = FileManager.default.displayName(atPath: folder.path)
        if result.failed > 0 {
            let verb = mode == .move ? "move" : "copy"
            showToast(result.failed == 1 ? "Couldn’t \(verb) 1 file" : "Couldn’t \(verb) \(result.failed) files",
                      symbol: "exclamationmark.triangle")
        } else if !result.done.isEmpty {
            let count = result.done.count == 1 ? result.done[0].to.lastPathComponent : "\(result.done.count) files"
            showToast("\(mode.past) \(count) to \(name)", symbol: mode == .move ? "folder" : "plus.square.on.square")
        }
        return !result.done.isEmpty
    }

    /// True if all the files are in this tab.
    func containsAll(_ urls: [URL]) -> Bool {
        urls.allSatisfy { url in allItems.contains { $0.url.isSameFile(as: url) } }
    }

    /// Scans the source again and keeps the current image selected if it still exists.
    func reload(selecting url: URL?) {
        guard let source else { return }
        isScanning = true
        let key = sortKey
        let ascending = sortAscending
        let pinned = Workspace.shared.pinnedFiles
        // A smart list becomes the list of its files now. The scan runs in the background.
        let scanned: ImageSource
        if case .smart(let list) = source {
            scanned = .files(Workspace.shared.urls(for: list))
        } else {
            scanned = source
        }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                FolderScanner.scan(scanned, sortedBy: key, ascending: ascending, pinned: pinned)
            }.value
            guard let self, !Task.isCancelled, self.source == source else { return }
            self.apply(scanned, selecting: url)
            // A pin that changed during the scan moves its file now.
            if Workspace.shared.pinnedFiles != pinned { self.resort() }
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
        let oldDates = Dictionary(allItems.map { ($0.url, $0.modified) }, uniquingKeysWith: { first, _ in first })
        for item in scanned where oldDates[item.url].map({ $0 != item.modified }) ?? false {
            pipeline.invalidate(item.url)
        }
        allItems = scanned
        items = scanned.filter(filter.allows)
        if let target, let found = items.firstIndex(where: { $0.url.isSameFile(as: target) }) {
            index = found
        } else {
            index = min(index, max(items.count - 1, 0))
        }
        guard hasItems else {
            clearCanvas()
            return
        }
        if current != previous || !hasViewerContent {
            rotation = 0
            if !isGridMode { loadCurrent() }
            if showInfo { loadInfo() }
        }
    }

    private func resort() {
        let selected = current?.url
        allItems = FolderScanner.sorted(allItems, by: sortKey, ascending: sortAscending,
                                        pinned: Workspace.shared.pinnedFiles)
        items = allItems.filter(filter.allows)
        if let selected, let found = items.firstIndex(where: { $0.url == selected }) {
            index = found
        }
    }

    private func applyFilter() {
        let previous = current
        items = allItems.filter(filter.allows)
        if let previous, let found = items.firstIndex(where: { $0.url == previous.url }) {
            index = found
        } else {
            index = min(index, max(items.count - 1, 0))
        }
        guard hasItems else {
            if !allItems.isEmpty { clearCanvas() }
            return
        }
        if current != previous || !hasViewerContent {
            rotation = 0
            if !isGridMode { loadCurrent() }
            if showInfo { loadInfo() }
        }
    }

    func toggleFormat(_ format: String) {
        var changed = filter
        if changed.formats.contains(format) { changed.formats.remove(format) } else { changed.formats.insert(format) }
        filter = changed
    }

    private func clearCanvas() {
        loadTask?.cancel()
        base = nil
        canvasContent = nil
        ambientImage = nil
        ambientKey = nil
        loadFailed = false
        info = nil
        stopVideo()
        closeDocument()
    }

    // MARK: - Navigation

    func go(to newIndex: Int) {
        guard items.indices.contains(newIndex), newIndex != index || !hasViewerContent else { return }
        direction = newIndex >= index ? 1 : -1
        index = newIndex
        rotation = 0
        if !isGridMode { loadCurrent() }
        if showInfo { loadInfo() }
        announceCurrent()
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
        if enabled {
            video.pause()
        } else if let url = current?.url, !(displayedURL.map { $0.isSameFile(as: url) } ?? false) {
            loadCurrent()
        } else {
            describeCurrentIfNeeded()
        }
    }

    /// The video stays in the player (paused) while the grid shows. So does the document.
    private var displayedURL: URL? { video.url ?? document?.url ?? canvasContent?.url }

    func openViewer(at newIndex: Int) {
        guard items.indices.contains(newIndex) else { return }
        if newIndex != index { rotation = 0 }
        index = newIndex
        setGridMode(false)
        if showInfo { loadInfo() }
        announceCurrent()
    }

    // MARK: - Loading

    private func loadCurrent() {
        loadTask?.cancel()
        rotateTask?.cancel()
        guard let item = current else {
            clearCanvas()
            return
        }
        loadFailed = false
        Workspace.shared.markSeen(item.url)
        // A photo from a phone shows as a preview until its full file arrives.
        DeviceLibrary.shared.wantFull([item.url])
        switch item.kind {
        case .image:
            if video.url != nil { stopVideo() }
            closeDocument()
            loadImage(item.url)
        case .video:
            closeDocument()
            loadVideo(item.url)
        case .document:
            if video.url != nil { stopVideo() }
            loadDocument(item)
        }
        prefetchNeighbors()
        describeCurrentIfNeeded()
    }

    private func loadImage(_ url: URL) {
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
    }

    private func loadVideo(_ url: URL) {
        // The canvas stays empty under a video.
        base = nil
        canvasContent = nil
        if let resumed = video.load(url) {
            showToast("Resumed at \(ImageMetadata.formatDuration(resumed))", symbol: "clock.arrow.circlepath")
        }

        let cached = pipeline.cachedThumbnail(for: url)
        videoSize = cached?.fullPixelSize
        if let cached { setAmbient(cached.image, for: url) }
        loadTask = Task { [weak self, pipeline] in
            async let thumbnail = pipeline.thumbnail(for: url)
            let size = await VideoDecoder.displaySize(of: AVURLAsset(url: url))
            guard let self, !Task.isCancelled, self.video.url == url else { return }
            // A file with only sound still gets an area for the player controls.
            if self.videoSize == nil { self.videoSize = size ?? CGSize(width: 16, height: 9) }
            guard let thumbnail = await thumbnail, !Task.isCancelled, self.video.url == url else { return }
            self.setAmbient(thumbnail.image, for: url)
        }
    }

    /// Stops the playback and closes the video file.
    func stopVideo() {
        video.close()
        videoSize = nil
    }

    private func loadDocument(_ item: ImageItem) {
        // The canvas stays empty under a document. A blurred page would only make a gray ambient background.
        base = nil
        canvasContent = nil
        ambientImage = nil
        ambientKey = nil
        let url = item.url
        guard DocumentDecoder.isPDF(url) else {
            documentPage = nil
            document = .preview(url, modified: item.modified)
            return
        }
        // The previous document stays until the PDF is open. This avoids a blank flash.
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { DocumentDecoder.loadPDF(url) }.value
            guard let self, !Task.isCancelled, self.current?.url == url else { return }
            self.documentPage = nil
            if let loaded {
                self.document = .pdf(url, loaded.document)
            } else {
                self.loadFailed = true
                self.document = nil
            }
        }
    }

    private func closeDocument() {
        document = nil
        documentPage = nil
    }

    /// Called by the PDF view when a different page scrolls into view.
    func documentPageChanged(_ page: DocumentPage?) {
        if documentPage != page { documentPage = page }
    }

    private var pdfView: DocumentPDFView? {
        showsPDF ? documentView as? DocumentPDFView : nil
    }

    /// Makes the document view receive the keys that scroll it.
    func focusDocument() {
        guard showsDocument, let view = documentView, let window = view.window else { return }
        // Quick Look shows Office files in a web view inside its own view. Only the web view scrolls with the keys.
        let target = view is DocumentPDFView ? view : view.deepestKeyView ?? view
        if window.firstResponder !== target { window.makeFirstResponder(target) }
    }

    private func prefetchNeighbors() {
        guard let current else { return }
        // Videos stream from the file and documents open quickly, so only images are decoded ahead.
        let neighbors = [index + direction, index + 2 * direction, index - direction]
            .filter { items.indices.contains($0) && items[$0].kind == .image }
            .map { items[$0].url }
        pipeline.cancelFullRequests(except: Set(neighbors + [current.url]))
        neighbors.forEach(pipeline.prefetch)
        DeviceLibrary.shared.wantFull(neighbors)
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
            let loaded = await Task.detached(priority: .utility) { await ImageMetadata.load(url) }.value
            guard let self, !Task.isCancelled, self.current?.url == url else { return }
            self.info = loaded
        }
    }

    // MARK: - Commands

    func rotate(by turns: Int) {
        if let pdfView {
            pdfView.rotatePages(by: turns)
            return
        }
        guard showsImage, base != nil else { return }
        rotation = ((rotation + turns) % 4 + 4) % 4
        applyRotation()
    }

    func zoomIn() {
        if isGridMode {
            gridTileSize = min(gridTileSize + 40, Self.gridTileSizes.upperBound)
        } else if let pdfView {
            pdfView.zoomIn()
            reportZoom(of: pdfView)
        } else if showsImage {
            canvas?.zoomIn()
        }
    }

    func zoomOut() {
        if isGridMode {
            gridTileSize = max(gridTileSize - 40, Self.gridTileSizes.lowerBound)
        } else if let pdfView {
            pdfView.zoomOut()
            reportZoom(of: pdfView)
        } else if showsImage {
            canvas?.zoomOut()
        }
    }

    func zoomToFit() {
        if let pdfView {
            pdfView.zoomToFit()
            reportZoom(of: pdfView)
        } else if showsImage {
            canvas?.zoomToFit(animated: true, userInitiated: true)
        }
    }

    func zoomToActualSize() {
        if let pdfView {
            pdfView.zoomToActualSize()
            reportZoom(of: pdfView)
        } else if showsImage {
            canvas?.zoomToActualSize()
        }
    }

    func toggleZoom() {
        if let pdfView {
            pdfView.toggleZoom()
            reportZoom(of: pdfView)
        } else if showsImage {
            canvas?.toggleZoom()
        }
    }

    private func reportZoom(of pdfView: DocumentPDFView) {
        canvasDidZoom(percent: pdfView.zoomPercent, isFit: pdfView.isFitMode)
    }

    // MARK: - Video

    func togglePlayback() {
        guard showsVideo else { return }
        let isPlaying = video.togglePlayback()
        showToast(isPlaying ? "Play" : "Pause", symbol: isPlaying ? "play.fill" : "pause.fill")
    }

    /// Positive values move forward. 5 and 10 seconds have their own symbols.
    func seekVideo(by seconds: Double) {
        guard showsVideo, let time = video.seek(by: seconds), let duration = video.duration else { return }
        let symbol = seconds < 0 ? "gobackward.\(Int(-seconds))" : "goforward.\(Int(seconds))"
        showToast("\(ImageMetadata.formatDuration(time)) / \(ImageMetadata.formatDuration(duration))", symbol: symbol)
    }

    func stepVideoFrame(by frames: Int) {
        guard showsVideo else { return }
        video.step(by: frames)
    }

    func changeVideoSpeed(by steps: Int) {
        guard showsVideo else { return }
        showSpeedToast(video.changeSpeed(by: steps))
    }

    func resetVideoSpeed() {
        guard showsVideo else { return }
        video.setSpeed(1)
        showSpeedToast(1)
    }

    private func showSpeedToast(_ speed: Float) {
        showToast("Speed \(String(format: "%g", speed))×", symbol: "gauge.with.needle")
    }

    func changeVolume(by delta: Float) {
        guard showsVideo else { return }
        let volume = video.changeVolume(by: delta)
        let symbol = volume == 0 ? "speaker.fill" : volume < 0.34 ? "speaker.wave.1.fill"
            : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        showToast("Volume \(Int((volume * 100).rounded()))%", symbol: symbol)
    }

    func toggleMute() {
        guard showsVideo else { return }
        video.player.isMuted.toggle()
        showToast(video.player.isMuted ? "Mute" : "Sound On",
                  symbol: video.player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }

    func toggleLoop() {
        video.isLooping.toggle()
        showToast(video.isLooping ? "Loop On" : "Loop Off", symbol: "repeat")
    }

    func copyCurrentFrame() {
        guard showsVideo else { return }
        Task { [weak self] in
            guard let self else { return }
            if let frame = await self.video.currentFrame() {
                PasteboardWriter.copyImage(frame)
                self.showToast("Frame copied", symbol: "photo.on.rectangle")
            } else {
                self.showToast("Couldn’t copy the frame", symbol: "exclamationmark.triangle")
            }
        }
    }

    // MARK: - Files

    func copyCurrent() {
        guard let item = current else { return }
        // A phone photo that is still a preview: copy it when its full file is here.
        if DeviceLibrary.shared.isPreview(item.url) {
            showToast("Getting the full photo from the phone…", symbol: "arrow.down.circle")
            Task { [weak self] in
                await DeviceLibrary.shared.ensureFull([item.url])
                guard let self, self.current?.url == item.url else { return }
                if DeviceLibrary.shared.isPreview(item.url) {
                    self.showToast("Couldn’t get the full photo from the phone", symbol: "exclamationmark.triangle")
                } else {
                    self.copyCurrent()
                }
            }
            return
        }
        if item.kind == .image {
            PasteboardWriter.copyImage(at: item.url)
        } else {
            PasteboardWriter.copyFile(at: item.url)
        }
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

    // MARK: - Stars, pins and tags

    /// Stars a file, or removes the star. Without a URL, it uses the current file.
    func toggleStar(_ url: URL? = nil) {
        guard let url = url ?? current?.url else { return }
        let starred = Workspace.shared.toggleStar(url)
        showToast(starred ? "Starred" : "Star removed", symbol: starred ? "star.fill" : "star.slash")
    }

    /// Pins a file to the top of its folder, or unpins it. Without a URL, it uses the current file.
    func toggleFilePin(_ url: URL? = nil) {
        guard let url = url ?? current?.url else { return }
        let pinned = Workspace.shared.toggleFilePin(url)
        showToast(pinned ? "Pinned to the top" : "Unpinned", symbol: pinned ? "pin.fill" : "pin.slash")
    }

    /// Pins a folder to Favorites, or unpins it. Without a URL, it uses the current folder.
    func toggleFolderPin(_ url: URL? = nil) {
        guard let url = url ?? currentFolder else { return }
        switch Workspace.shared.toggleFolderPin(url) {
        case true?: showToast("Pinned to Favorites", symbol: "pin.fill")
        case false?: showToast("Unpinned from Favorites", symbol: "pin.slash")
        case nil: showToast("Couldn’t pin this folder", symbol: "exclamationmark.triangle")
        }
    }

    func toggleTag(_ tag: FinderTag) {
        guard let url = current?.url else { return }
        guard let added = Workspace.shared.toggleTag(tag, for: url) else {
            showToast("Couldn’t change the tags", symbol: "exclamationmark.triangle")
            return
        }
        showToast(added ? tag.name : "Removed \(tag.name)", symbol: added ? "tag.fill" : "tag.slash")
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
        allItems.removeAll { $0.url.isSameFile(as: url) }
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

    // MARK: - Accessibility

    /// The position of the current file, for example "3 of 120".
    private var positionDescription: String { "\(index + 1) of \(items.count)" }

    /// What VoiceOver reads for the image on the canvas: the name, the position and the description.
    var canvasAccessibilityLabel: String {
        guard let current else { return "" }
        var text = "\(current.name), \(positionDescription)"
        if let description = currentDescription { text += ". \(description.spoken)" }
        return text
    }

    /// The description of the current image. It is nil until Vision is done.
    var currentDescription: ImageDescription? {
        guard let description = imageDescription, description.url == current?.url else { return nil }
        return description
    }

    /// VoiceOver does not follow the arrow keys, so it reads the name of each new file.
    private func announceCurrent() {
        guard let current, Accessibility.isVoiceOverOn else { return }
        Accessibility.announce("\(current.name), \(positionDescription)")
    }

    /// Vision describes the current image when VoiceOver is on or the info panel shows.
    private func describeCurrentIfNeeded() {
        guard let item = current, item.kind == .image, !isGridMode, showInfo || Accessibility.isVoiceOverOn,
              imageDescription?.url != item.url else { return }
        describeTask?.cancel()
        let url = item.url
        describeTask = Task { [weak self] in
            let description = await ImageDescriber.shared.describe(url)
            guard let self, !Task.isCancelled, let description, self.current?.url == url else { return }
            self.imageDescription = description
            // A low priority does not cut off the name of the file.
            if !self.isGridMode { Accessibility.announce(description.spoken, priority: .low) }
        }
    }

    /// Full Keyboard Access moved the focus to a control in the viewer, or away from it.
    func setControlFocus(_ focused: Bool, id: UUID) {
        if focused { focusedControls.insert(id) } else { focusedControls.remove(id) }
    }

    /// True when a button in the viewer has the keyboard focus. Space and Return then press it.
    var controlHasKeyboardFocus: Bool { !focusedControls.isEmpty }

    // MARK: - Toasts

    func showToast(_ message: String, symbol: String? = nil) {
        let toast = Toast(message: message, symbol: symbol)
        self.toast = toast
        // VoiceOver reads "·" as a word.
        Accessibility.announce(message.replacingOccurrences(of: "  ·  ", with: ", "), priority: .medium)
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
