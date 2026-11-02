import Foundation
import ImageIO
import Vision

/// What Vision finds in an image: the things in it, the faces and the text.
struct ImageDescription: Sendable, Equatable {
    let url: URL
    /// The most likely things in the image, for example "dog", "grass" and "outdoor".
    let labels: [String]
    let faces: Int
    /// The text in the image, if there is text.
    let text: String?

    /// One sentence for VoiceOver, for example "Shows dog, grass, outdoor. 2 faces. Text: Open 9 to 5."
    var spoken: String {
        var parts: [String] = []
        if !labels.isEmpty { parts.append("Shows \(labels.joined(separator: ", "))") }
        if faces > 0 { parts.append(faces == 1 ? "1 face" : "\(faces) faces") }
        if let text { parts.append("Text: \(text)") }
        return parts.isEmpty ? "No description" : parts.joined(separator: ". ") + "."
    }
}

/// Makes text descriptions of images with Vision, on the device. VoiceOver reads them, and the info panel shows them.
actor ImageDescriber {
    static let shared = ImageDescriber()

    /// Vision does not need the full image. A smaller image is faster, and it still has readable text.
    private static let maxPixelSize = 2048
    private static let maxLabels = 6
    /// Labels that say little about a photo. Vision gives them together with better labels, for example "water body".
    private static let vagueLabels: Set<String> = ["structure", "liquid", "land", "material", "conveyance"]
    private static let maxTextLength = 400

    private var cache: [URL: ImageDescription] = [:]
    private var order: [URL] = []

    func describe(_ url: URL) async -> ImageDescription? {
        if let cached = cache[url] { return cached }
        guard let image = Self.loadImage(url), !Task.isCancelled else { return nil }
        guard let description = Self.analyze(image, url: url) else { return nil }
        cache[url] = description
        order.append(url)
        if order.count > 300 { cache[order.removeFirst()] = nil }
        return description
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func analyze(_ image: CGImage, url: URL) -> ImageDescription? {
        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([classify, faces, text])
        } catch {
            return nil
        }

        // Keep only the labels that Vision is sure of, as Apple recommends: few false labels, even if some are missing.
        let sure = (classify.results ?? [])
            .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
            .sorted { $0.confidence > $1.confidence }
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            .filter { !vagueLabels.contains($0) }
        // "blue sky" says more than "sky". Drop a label when a longer label has it as a word.
        let labels = sure
            .filter { label in !sure.contains { $0 != label && $0.split(separator: " ").contains(Substring(label)) } }
            .prefix(maxLabels)

        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        var recognized = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if recognized.count > maxTextLength {
            recognized = String(recognized.prefix(maxTextLength)) + "…"
        }

        return ImageDescription(url: url, labels: Array(labels), faces: faces.results?.count ?? 0,
                                text: recognized.isEmpty ? nil : recognized)
    }
}
