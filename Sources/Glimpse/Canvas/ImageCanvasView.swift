import AppKit
import QuartzCore

/// What the canvas shows.
struct CanvasContent {
    let url: URL
    let image: CGImage
    let animated: NSImage?
    /// The size of the document in image pixels. A placeholder thumbnail uses the full image size,
    /// so the zoom does not change when the full image replaces it.
    let pixelSize: CGSize
    let rotation: Int
}

@MainActor
protocol ImageCanvasDelegate: AnyObject {
    func canvasDidZoom(percent: Int, isFit: Bool)
    func canvasRequestsNavigation(by delta: Int)
    func canvasPointerExited()
}

/// A zoomable, pannable image view.
///
/// One document unit is one image pixel. A magnification of `1 / backingScaleFactor`
/// shows one image pixel on one screen pixel (100%).
final class ImageCanvasView: NSScrollView {
    weak var canvasDelegate: ImageCanvasDelegate?

    private let centeringClipView = CenteringClipView()
    private let imageView = ImageDocumentView()
    private var identity: (url: URL, rotation: Int)?
    private(set) var isFitMode = true

    private var dragStart: (location: NSPoint, origin: NSPoint)?
    /// The mouse-down event of a press that drags the file out when the pointer moves.
    private var fileDragEvent: NSEvent?
    private var swipeDistance: CGFloat = 0
    private var swipeConsumed = false
    private var showsHandCursor = false
    private var trackingArea: NSTrackingArea?
    private var zoomAnimation: ZoomAnimation?
    private var displayLink: CADisplayLink?

    /// What VoiceOver reads for the image: the name, the position and a description.
    var accessibilityText = ""
    /// The commands that VoiceOver offers in its Actions menu, for example "Next Image" and "Zoom In".
    var accessibilityCommands: [(name: String, perform: () -> Void)] = []

    private struct ZoomAnimation {
        let from: CGFloat
        let to: CGFloat
        let anchor: NSPoint
        let start: CFTimeInterval
        let duration: CFTimeInterval
    }

    private static let zoomSteps: [CGFloat] = [
        0.05, 0.1, 0.125, 0.167, 0.25, 0.333, 0.5, 0.667, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32,
    ]

    /// Space covered by the toolbar, the filmstrip and the info panel.
    /// "Fit" fits the image in the rest of the view, but the image can still scroll under the covered space.
    var fitInsets = NSEdgeInsetsZero {
        didSet {
            guard !NSEdgeInsetsEqual(fitInsets, oldValue) else { return }
            centeringClipView.centeringInsets = fitInsets
            if isFitMode {
                zoomToFit(animated: identity != nil && window != nil)
            } else {
                clampVisibleRect()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = centeringClipView
        documentView = imageView
        drawsBackground = false
        centeringClipView.drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        allowsMagnification = true
        minMagnification = 0.002
        maxMagnification = 32
        imageView.frame = .zero

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(liveMagnifyWillStart),
                           name: NSScrollView.willStartLiveMagnifyNotification, object: self)
        center.addObserver(self, selector: #selector(liveMagnifyDidEnd),
                           name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Content

    func setContent(_ content: CanvasContent?) {
        guard let content else {
            if identity != nil {
                identity = nil
                imageView.setImage(nil, animated: nil)
                imageView.setFrameSize(.zero)
            }
            return
        }
        imageView.setImage(content.image, animated: content.animated)
        let isNewImage = identity.map { !$0.url.isSameFile(as: content.url) || $0.rotation != content.rotation } ?? true
        if isNewImage {
            identity = (content.url, content.rotation)
            stopZoomAnimation()
            imageView.setFrameSize(content.pixelSize)
            zoomToFit(animated: false)
        } else if imageView.frame.size != content.pixelSize {
            // Same image at a new resolution: keep the size on screen.
            let ratio = imageView.frame.width / max(content.pixelSize.width, 1)
            imageView.setFrameSize(content.pixelSize)
            if isFitMode {
                zoomToFit(animated: false)
            } else {
                magnification *= ratio
                clampVisibleRect()
            }
        }
    }

    // MARK: - Zoom

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Image pixels per screen pixel. 1 means 100%.
    private var pixelRatio: CGFloat { magnification * backingScale }

    private var availableSize: CGSize {
        CGSize(width: max(1, bounds.width - fitInsets.left - fitInsets.right),
               height: max(1, bounds.height - fitInsets.top - fitInsets.bottom))
    }

    private var fitMagnification: CGFloat {
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0 else { return 1 }
        let available = availableSize
        // Do not enlarge small images past one image pixel per point.
        return min(1, available.width / size.width, available.height / size.height)
    }

    private var canPan: Bool {
        let size = imageView.frame.size
        let available = availableSize
        return size.width * magnification > available.width + 0.5
            || size.height * magnification > available.height + 0.5
    }

    /// The center of the uncovered area, in document coordinates.
    private var visibleCenter: NSPoint {
        let visible = centeringClipView.bounds
        let scale = magnification
        let available = availableSize
        return NSPoint(x: visible.minX + (fitInsets.left + available.width / 2) / scale,
                       y: visible.minY + (fitInsets.bottom + available.height / 2) / scale)
    }

    func zoomToFit(animated: Bool, userInitiated: Bool = false) {
        isFitMode = true
        let target = fitMagnification
        if animated {
            animateMagnification(to: target, around: visibleCenter)
        } else {
            stopZoomAnimation()
            minMagnification = min(minMagnification, target)
            magnification = target
            clampVisibleRect()
            zoomSettled()
        }
        if userInitiated { report(target) }
    }

    func zoomIn() {
        let next = Self.zoomSteps.first { $0 > pixelRatio * 1.02 } ?? pixelRatio * 1.5
        zoom(toPixelRatio: next, around: visibleCenter)
    }

    func zoomOut() {
        let previous = Self.zoomSteps.last { $0 < pixelRatio / 1.02 } ?? pixelRatio / 1.5
        if previous / backingScale <= fitMagnification * 1.01 {
            zoomToFit(animated: true, userInitiated: true)
        } else {
            zoom(toPixelRatio: previous, around: visibleCenter)
        }
    }

    func zoomToActualSize() {
        zoom(toPixelRatio: 1, around: visibleCenter)
    }

    /// Switches between "fit" and a close-up view.
    func toggleZoom(around point: NSPoint? = nil) {
        // Nothing to zoom, for example around a video or while the first image loads.
        guard identity != nil else { return }
        let fit = fitMagnification
        if isFitMode || magnification <= fit * 1.01 {
            var target = 1 / backingScale
            if target < fit * 1.25 { target = fit * 2.5 }
            isFitMode = false
            let clamped = min(target, maxMagnification)
            animateMagnification(to: clamped, around: point ?? visibleCenter)
            report(clamped)
        } else {
            zoomToFit(animated: true, userInitiated: true)
        }
    }

    private func zoom(toPixelRatio ratio: CGFloat, around point: NSPoint) {
        guard identity != nil else { return }
        let target = min(ratio / backingScale, maxMagnification)
        if target <= fitMagnification * 1.001 {
            zoomToFit(animated: true, userInitiated: true)
            return
        }
        isFitMode = false
        animateMagnification(to: target, around: point)
        report(target)
    }

    private func animateMagnification(to target: CGFloat, around anchor: NSPoint) {
        minMagnification = min(minMagnification, target)
        if Accessibility.reduceMotion {
            stopZoomAnimation()
            setMagnification(target, centeredAt: anchor)
            if isFitMode { clampVisibleRect() }
            zoomSettled()
            return
        }
        zoomAnimation = ZoomAnimation(from: magnification, to: target, anchor: anchor,
                                      start: CACurrentMediaTime(), duration: 0.22)
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(stepZoomAnimation(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func stepZoomAnimation(_ link: CADisplayLink) {
        guard let animation = zoomAnimation else {
            stopZoomAnimation()
            return
        }
        let progress = min(1, (CACurrentMediaTime() - animation.start) / animation.duration)
        let eased = 1 - pow(1 - progress, 3)
        // Interpolate in log space, so each frame changes the scale by the same factor.
        let value = exp(log(animation.from) + (log(animation.to) - log(animation.from)) * eased)
        setMagnification(value, centeredAt: animation.anchor)
        if progress >= 1 {
            stopZoomAnimation()
            if isFitMode { clampVisibleRect() }
            zoomSettled()
        }
    }

    private func stopZoomAnimation() {
        zoomAnimation = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    private func zoomSettled() {
        // Let a pinch go a little below "fit". It springs back when the pinch ends.
        minMagnification = max(0.002, min(magnification, fitMagnification * 0.5))
        imageView.usesNearestNeighbor = pixelRatio >= 3
        window?.invalidateCursorRects(for: self)
    }

    private func report(_ magnification: CGFloat) {
        let percent = Int((magnification * backingScale * 100).rounded())
        let fit = isFitMode
        // Do not change SwiftUI state during a view update.
        DispatchQueue.main.async { [weak self] in
            self?.canvasDelegate?.canvasDidZoom(percent: percent, isFit: fit)
        }
    }

    @objc private func liveMagnifyWillStart(_ notification: Notification) {
        stopZoomAnimation()
        isFitMode = false
    }

    @objc private func liveMagnifyDidEnd(_ notification: Notification) {
        if magnification <= fitMagnification * 1.02 {
            zoomToFit(animated: true)
        } else {
            zoomSettled()
            report(magnification)
        }
    }

    private func clampVisibleRect() {
        let constrained = centeringClipView.constrainBoundsRect(centeringClipView.bounds)
        centeringClipView.scroll(to: constrained.origin)
        reflectScrolledClipView(centeringClipView)
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if isFitMode {
            stopZoomAnimation()
            let target = fitMagnification
            minMagnification = min(minMagnification, target)
            magnification = target
            clampVisibleRect()
        } else {
            clampVisibleRect()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        zoomSettled()
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        fileDragEvent = nil
        if event.clickCount >= 2 {
            toggleZoom(around: imageView.convert(event.locationInWindow, from: nil))
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if canPan && !flags.contains(.command) {
            stopZoomAnimation()
            dragStart = (event.locationInWindow, centeringClipView.bounds.origin)
            NSCursor.closedHand.set()
        } else if isOverImage(event) {
            // A drag on the image that fits, or a ⌘-drag on a zoomed image, takes the file to another app.
            fileDragEvent = event
        } else if let window, !window.styleMask.contains(.fullScreen) {
            window.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let down = fileDragEvent {
            let distance = hypot(event.locationInWindow.x - down.locationInWindow.x,
                                 event.locationInWindow.y - down.locationInWindow.y)
            if distance > 3 {
                fileDragEvent = nil
                beginFileDrag(with: event)
            }
            return
        }
        guard let start = dragStart else { return }
        let scale = magnification
        var origin = start.origin
        origin.x -= (event.locationInWindow.x - start.location.x) / scale
        origin.y -= (event.locationInWindow.y - start.location.y) / scale
        let rect = centeringClipView.constrainBoundsRect(NSRect(origin: origin, size: centeringClipView.bounds.size))
        centeringClipView.scroll(to: rect.origin)
        reflectScrolledClipView(centeringClipView)
    }

    override func mouseUp(with event: NSEvent) {
        fileDragEvent = nil
        guard dragStart != nil else { return }
        dragStart = nil
        updateCursor(for: event)
    }

    override func smartMagnify(with event: NSEvent) {
        toggleZoom(around: imageView.convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) || !event.hasPreciseScrollingDeltas {
            zoomWithScrollWheel(event)
        } else if canPan {
            super.scrollWheel(with: event)
        } else {
            trackSwipe(event)
        }
    }

    /// Mouse wheel, or a trackpad scroll with ⌘ or ⌥, zooms around the pointer.
    private func zoomWithScrollWheel(_ event: NSEvent) {
        guard identity != nil else { return }
        // Positive means "away from the user", whatever the natural scrolling setting is.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard delta != 0 else { return }
        let factor = event.hasPreciseScrollingDeltas ? exp(delta * 0.01) : pow(1.15, max(-4, min(4, delta)))
        stopZoomAnimation()
        let fit = fitMagnification
        let target = min(magnification * factor, maxMagnification)
        if target <= fit * 1.001 {
            if !isFitMode { zoomToFit(animated: true, userInitiated: true) }
            return
        }
        isFitMode = false
        setMagnification(target, centeredAt: imageView.convert(event.locationInWindow, from: nil))
        zoomSettled()
        report(target)
    }

    /// A horizontal two-finger swipe moves to the next or previous image when the image fits.
    private func trackSwipe(_ event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swipeDistance = 0
            swipeConsumed = false
        }
        guard event.phase.contains(.changed), !swipeConsumed else { return }
        // Positive means the fingers move to the right.
        let fingerDelta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        swipeDistance += fingerDelta
        if abs(swipeDistance) > 60, abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) {
            swipeConsumed = true
            canvasDelegate?.canvasRequestsNavigation(by: swipeDistance < 0 ? 1 : -1)
        }
    }

    // MARK: - Drag out

    /// The part of the canvas that shows the image.
    private var imageRect: NSRect {
        convert(imageView.bounds, from: imageView).intersection(bounds)
    }

    private func isOverImage(_ event: NSEvent) -> Bool {
        identity != nil && imageRect.contains(convert(event.locationInWindow, from: nil))
    }

    private func beginFileDrag(with event: NSEvent) {
        guard let url = identity?.url, let image = imageView.image else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(dragFrame(around: convert(event.locationInWindow, from: nil)),
                              contents: NSImage(cgImage: image, size: .zero))
        OutgoingDrag.begin([url])
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// The image on screen, made smaller around the pointer when it is large.
    private func dragFrame(around point: NSPoint) -> NSRect {
        let rect = imageRect
        let scale = min(1, 240 / max(rect.width, rect.height, 1))
        return NSRect(x: point.x - (point.x - rect.minX) * scale,
                      y: point.y - (point.y - rect.minY) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        canvasDelegate?.canvasPointerExited()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { identity != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { accessibilityText }

    override func accessibilityValue() -> Any? {
        guard identity != nil else { return nil }
        let percent = Int((pixelRatio * 100).rounded())
        return isFitMode ? "Zoom to fit, \(percent)%" : "Zoom \(percent)%"
    }

    /// The image is one element. VoiceOver does not need the clip view or the image view in it.
    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        accessibilityCommands.map { command in
            NSAccessibilityCustomAction(name: command.name) {
                command.perform()
                return true
            }
        }
    }

    private func updateCursor(for event: NSEvent) {
        guard dragStart == nil else { return }
        // SwiftUI overlays (filmstrip, buttons) sit above the canvas. Show the hand only over the image area.
        let isOverCanvas = window?.contentView?.hitTest(event.locationInWindow) === self
        if isOverCanvas && canPan {
            NSCursor.openHand.set()
            showsHandCursor = true
        } else if showsHandCursor {
            NSCursor.arrow.set()
            showsHandCursor = false
        }
    }
}

/// Centers the image in the uncovered area when it is smaller than that area.
final class CenteringClipView: NSClipView {
    var centeringInsets = NSEdgeInsetsZero

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        guard let documentView, proposedBounds.width > 0 else { return super.constrainBoundsRect(proposedBounds) }
        var rect = proposedBounds
        let scale = frame.width / proposedBounds.width
        let document = documentView.frame
        let insets = centeringInsets
        rect.origin.x = Self.constrain(origin: rect.minX, length: rect.width,
                                       documentStart: document.minX, documentLength: document.width,
                                       leading: insets.left / scale, trailing: insets.right / scale)
        let bottom = (isFlipped ? insets.top : insets.bottom) / scale
        let top = (isFlipped ? insets.bottom : insets.top) / scale
        rect.origin.y = Self.constrain(origin: rect.minY, length: rect.height,
                                       documentStart: document.minY, documentLength: document.height,
                                       leading: bottom, trailing: top)
        return rect
    }

    private static func constrain(origin: CGFloat, length: CGFloat, documentStart: CGFloat,
                                  documentLength: CGFloat, leading: CGFloat, trailing: CGFloat) -> CGFloat {
        let available = length - leading - trailing
        if documentLength <= available {
            return documentStart + documentLength / 2 - leading - available / 2
        }
        let lowest = documentStart - leading
        let highest = documentStart + documentLength + trailing - length
        return min(max(origin, lowest), highest)
    }
}

/// Shows the image as layer contents, so the GPU scales it while zooming.
final class ImageDocumentView: NSView {
    private(set) var image: CGImage?
    private var animatedView: NSImageView?

    var usesNearestNeighbor = false {
        didSet { if usesNearestNeighbor != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }

    override func updateLayer() {
        guard let layer else { return }
        // An animated image is shown by the image view. Do not show the first frame below it.
        layer.contents = animatedView == nil ? image : nil
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = usesNearestNeighbor ? .nearest : .linear
    }

    func setImage(_ newImage: CGImage?, animated: NSImage?) {
        if newImage !== image {
            image = newImage
            needsDisplay = true
        }
        if let animated {
            let view = animatedView ?? makeAnimatedView()
            if view.image !== animated { view.image = animated }
        } else if let animatedView {
            animatedView.removeFromSuperview()
            self.animatedView = nil
            needsDisplay = true
        }
    }

    private func makeAnimatedView() -> NSImageView {
        let view = NSImageView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.imageScaling = .scaleAxesIndependently
        view.animates = true
        view.isEditable = false
        addSubview(view)
        animatedView = view
        needsDisplay = true
        return view
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension ImageCanvasView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only, so a drop in Finder never moves the file out of its folder.
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        OutgoingDrag.end()
    }
}
