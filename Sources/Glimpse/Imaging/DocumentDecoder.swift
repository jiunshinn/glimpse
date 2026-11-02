import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A PDF that was opened in the background.
final class LoadedPDF: @unchecked Sendable {
    let document: PDFDocument

    init(document: PDFDocument) {
        self.document = document
    }
}

/// Reads documents. PDF files open with PDFKit. Word, Excel, PowerPoint and iWork files show with Quick Look,
/// which macOS includes, so Glimpse does not need the apps that made them.
enum DocumentDecoder {
    /// The document types that Glimpse shows in the folder sequence.
    /// Plain text is not included: a text file next to photos is usually a note, not a document to look at.
    static let types: [UTType] = [.pdf, .rtf, .spreadsheet, .presentation, .delimitedText] + [
        "org.openxmlformats.openxml",      // DOCX, XLSX, PPTX
        "com.microsoft.word.doc",
        "org.oasis-open.opendocument",     // ODT, ODS, ODP
        "com.apple.iwork.pages.sffpages",
    ].compactMap { UTType($0) }

    static func isDocument(_ type: UTType) -> Bool {
        types.contains { type.conforms(to: $0) }
    }

    static func isDocument(_ url: URL) -> Bool {
        contentType(of: url).map(isDocument) ?? false
    }

    static func isPDF(_ url: URL) -> Bool {
        contentType(of: url)?.conforms(to: .pdf) ?? false
    }

    /// Opens a PDF. Nil if the file is not a PDF or is damaged.
    static func loadPDF(_ url: URL) -> LoadedPDF? {
        PDFDocument(url: url).map(LoadedPDF.init)
    }

    /// The first page as Quick Look draws it, or the file icon if Quick Look cannot draw it.
    /// It blocks the thread until Quick Look is done, so call it only from an operation queue.
    static func thumbnail(_ url: URL, maxPixelSize: Int) -> Thumbnail? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: maxPixelSize, height: maxPixelSize), scale: 1, representationTypes: .all
        )
        let box = ImageBox()
        let semaphore = DispatchSemaphore(value: 0)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            box.image = representation?.cgImage
            semaphore.signal()
        }
        // A broken file can keep Quick Look busy. Do not block a thumbnail thread for long.
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            QLThumbnailGenerator.shared.cancel(request)
            return nil
        }
        guard let image = box.image else { return nil }
        return Thumbnail(image: image, fullPixelSize: CGSize(width: image.width, height: image.height))
    }

    // MARK: - Helpers

    private final class ImageBox: @unchecked Sendable {
        var image: CGImage?
    }

    private static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    }
}
