import SwiftUI

struct CanvasRepresentable: NSViewRepresentable {
    let model: ViewerModel

    func makeNSView(context: Context) -> ImageCanvasView {
        let view = ImageCanvasView(frame: .zero)
        view.canvasDelegate = model
        view.accessibilityCommands = [
            ("Next Image", { model.next() }),
            ("Previous Image", { model.previous() }),
            ("Zoom In", { model.zoomIn() }),
            ("Zoom Out", { model.zoomOut() }),
            ("Zoom to Fit", { model.zoomToFit() }),
            ("Actual Size", { model.zoomToActualSize() }),
            ("Rotate Right", { model.rotate(by: 1) }),
            ("Rotate Left", { model.rotate(by: -1) }),
            ("Show Grid", { model.setGridMode(true) }),
        ]
        model.canvas = view
        return view
    }

    func updateNSView(_ view: ImageCanvasView, context: Context) {
        view.fitInsets = model.canvasInsets
        view.setContent(model.canvasContent)
        view.accessibilityText = model.canvasAccessibilityLabel
    }
}
