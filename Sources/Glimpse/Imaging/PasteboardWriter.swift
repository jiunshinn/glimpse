import AppKit
import UniformTypeIdentifiers

/// Puts an image on the pasteboard as a file URL and as image data.
/// The image data is made only when an app pastes it.
@MainActor
enum PasteboardWriter {
    private static var provider: ImageDataProvider?

    static func copyImage(at url: URL) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let provider = ImageDataProvider(url: url)
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        self.provider = provider

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    static func copyPath(of url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }
}

private final class ImageDataProvider: NSObject, NSPasteboardItemDataProvider {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        // Give PNG files to the receiver as they are.
        if type == .png, (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType == .png,
           let data = try? Data(contentsOf: url) {
            item.setData(data, forType: type)
            return
        }
        guard let image = ImagePipeline.shared.cachedImage(for: url)?.cgImage
            ?? ImageDecoder.decodeFull(url)?.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        let data = type == .png ? rep.representation(using: .png, properties: [:]) : rep.tiffRepresentation
        if let data { item.setData(data, forType: type) }
    }
}
