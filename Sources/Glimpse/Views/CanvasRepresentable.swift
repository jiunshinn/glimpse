import SwiftUI

struct CanvasRepresentable: NSViewRepresentable {
    let model: ViewerModel

    func makeNSView(context: Context) -> ImageCanvasView {
        let view = ImageCanvasView(frame: .zero)
        view.canvasDelegate = model
        model.canvas = view
        return view
    }

    func updateNSView(_ view: ImageCanvasView, context: Context) {
        view.fitInsets = model.canvasInsets
        view.setContent(model.canvasContent)
    }
}
