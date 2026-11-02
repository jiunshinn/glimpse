import PDFKit
import Quartz
import SwiftUI

/// What the document stage shows.
enum DocumentContent {
    /// A PDF, shown with PDFKit.
    case pdf(URL, PDFDocument)
    /// Another document, shown with Quick Look. A new modification date loads the preview again.
    case preview(URL, modified: Date)

    var url: URL {
        switch self {
        case .pdf(let url, _), .preview(let url, _): url
        }
    }

    var isPDF: Bool {
        if case .pdf = self { true } else { false }
    }
}

/// The visible page of a PDF.
struct DocumentPage: Equatable {
    let index: Int
    let count: Int
}

/// Shows the current document in the uncovered area.
struct DocumentStage: View {
    let model: ViewerModel

    var body: some View {
        let insets = model.stageInsets
        Group {
            switch model.document {
            case .pdf(_, let document):
                PDFViewRepresentable(document: document, model: model)
            case .preview(let url, let modified):
                QuickLookRepresentable(url: url, modified: modified, model: model)
            case nil:
                Color.clear
            }
        }
        .padding(EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right))
    }
}

// MARK: - PDF

private struct PDFViewRepresentable: NSViewRepresentable {
    let document: PDFDocument
    let model: ViewerModel

    func makeNSView(context: Context) -> DocumentPDFView {
        let view = DocumentPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        // The black window shows around the pages, as it does around an image.
        view.backgroundColor = .black
        view.document = document
        context.coordinator.observe(view)
        model.documentView = view
        return view
    }

    func updateNSView(_ view: DocumentPDFView, context: Context) {
        guard view.document !== document else { return }
        view.document = document
        // A new document starts at the top, and the whole page fits.
        view.zoomToFit()
        context.coordinator.reportPage(of: view)
        view.takeFocus()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    static func dismantleNSView(_ view: DocumentPDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
        if coordinator.model.documentView === view { coordinator.model.documentView = nil }
    }

    @MainActor
    final class Coordinator {
        let model: ViewerModel
        private var observer: NSObjectProtocol?

        init(model: ViewerModel) {
            self.model = model
        }

        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.reportPage(of: view)
                }
            }
            reportPage(of: view)
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        func reportPage(of view: PDFView) {
            // Do not change SwiftUI state during a view update.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let document = view.document, let page = view.currentPage else { return }
                self.model.documentPageChanged(DocumentPage(index: document.index(for: page), count: document.pageCount))
            }
        }
    }
}

/// A PDF view that Glimpse can zoom and rotate from its own commands.
///
/// "Fit" shows the whole page, as the image canvas shows the whole image. PDFKit's own `autoScales` fits only the width,
/// which makes a page larger than a wide window.
final class DocumentPDFView: PDFView {
    private static let maxScale: CGFloat = 16

    /// True while the whole page fits. The page fits again when the view changes size.
    private(set) var isFitMode = true
    private var isSettingScale = false
    private var scaleObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        maxScaleFactor = Self.maxScale
        scaleObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // A pinch leaves "fit".
                guard let self, !self.isSettingScale else { return }
                self.isFitMode = false
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocus()
    }

    /// Without selected text, Copy goes on to the window, which copies the file.
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(NSText.copy(_:)), currentSelection?.string?.isEmpty ?? true { return false }
        return super.responds(to: selector)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if isFitMode, let fitScale { setScale(fitScale) }
    }

    /// Makes the view receive the keys that scroll the document.
    func takeFocus() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    /// The zoom in percent. 100% shows one PDF point on one screen point.
    var zoomPercent: Int { Int((scaleFactor * 100).rounded()) }

    func zoomToFit() {
        isFitMode = true
        if let fitScale { setScale(fitScale) }
    }

    func zoomToActualSize() {
        zoom(to: 1)
    }

    func zoomIn() {
        zoom(to: scaleFactor * 1.25)
    }

    func zoomOut() {
        zoom(to: scaleFactor / 1.25)
    }

    /// Switches between the whole page and the page width. If the width is not much larger, the close-up is twice "fit".
    func toggleZoom() {
        guard let fit = fitScale else { return }
        if isFitMode || scaleFactor <= fit * 1.01 {
            let width = widthFitScale
            zoom(to: width >= fit * 1.25 ? width : fit * 2)
        } else {
            zoomToFit()
        }
    }

    private func zoom(to scale: CGFloat) {
        if let fitScale, scale <= fitScale * 1.01 {
            zoomToFit()
        } else {
            isFitMode = false
            setScale(min(scale, Self.maxScale))
        }
    }

    private func setScale(_ scale: CGFloat) {
        guard abs(scale - scaleFactor) > 0.0001 else { return }
        // PDFKit keeps the center of the view in place. In "fit", keep the top of the current page in place instead.
        let page = isFitMode ? currentPage : nil
        autoScales = false
        isSettingScale = true
        scaleFactor = scale
        isSettingScale = false
        if let page { go(to: page) }
    }

    /// The scale that shows the whole current page. Nil before the view has a size.
    private var fitScale: CGFloat? {
        let available = availableSize
        guard let page = pageSize, page.width > 0, page.height > 0, available.width > 0, available.height > 0
        else { return nil }
        return min(available.width / page.width, available.height / page.height)
    }

    /// The scale that fills the width with the current page.
    private var widthFitScale: CGFloat {
        guard let page = pageSize, page.width > 0, availableSize.width > 0 else { return scaleFactor }
        return availableSize.width / page.width
    }

    private var availableSize: CGSize {
        let margins = pageBreakMargins
        return CGSize(width: bounds.width - margins.left - margins.right - 16,
                      height: bounds.height - margins.top - margins.bottom)
    }

    /// The size of the current page after its rotation, in PDF points.
    private var pageSize: CGSize? {
        guard let page = currentPage ?? document?.page(at: 0) else { return nil }
        let size = page.bounds(for: displayBox).size
        return page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// Turns every page by quarter turns. Positive values turn clockwise. The file does not change.
    func rotatePages(by quarterTurns: Int) {
        guard let document else { return }
        let page = currentPage
        for index in 0..<document.pageCount {
            guard let item = document.page(at: index) else { continue }
            item.rotation = ((item.rotation + quarterTurns * 90) % 360 + 360) % 360
        }
        layoutDocumentView()
        if isFitMode, let fitScale { setScale(fitScale) }
        if let page { go(to: page) }
    }
}

// MARK: - Quick Look

extension NSView {
    /// The deepest view in this view that accepts the keyboard focus.
    var deepestKeyView: NSView? {
        for subview in subviews.reversed() {
            if let found = subview.deepestKeyView { return found }
        }
        return acceptsFirstResponder ? self : nil
    }
}

private struct QuickLookRepresentable: NSViewRepresentable {
    let url: URL
    let modified: Date
    let model: ViewerModel

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        // The view closes in `dismantleNSView`. It can go away before the window closes.
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        context.coordinator.modified = modified
        model.documentView = view
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        } else if context.coordinator.modified != modified {
            view.refreshPreviewItem()
        }
        context.coordinator.modified = modified
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        if coordinator.model.documentView === view { coordinator.model.documentView = nil }
        view.close()
    }

    @MainActor
    final class Coordinator {
        let model: ViewerModel
        var modified: Date?

        init(model: ViewerModel) {
            self.model = model
        }
    }
}
