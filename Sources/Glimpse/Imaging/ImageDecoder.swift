import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A fully decoded image, ready for display.
final class DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
    /// Set for animated GIF, PNG and WebP files. `NSImageView` plays it.
    let animated: NSImage?

    init(cgImage: CGImage, animated: NSImage?) {
        self.cgImage = cgImage
        self.animated = animated
    }

    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
    var cost: Int { cgImage.bytesPerRow * cgImage.height }
}

/// A small preview, plus the pixel size of the full image.
final class Thumbnail: @unchecked Sendable {
    let image: CGImage
    let fullPixelSize: CGSize
    /// The length of a video in seconds. Nil for an image.
    let duration: Double?

    init(image: CGImage, fullPixelSize: CGSize, duration: Double? = nil) {
        self.image = image
        self.fullPixelSize = fullPixelSize
        self.duration = duration
    }

    var cost: Int { image.bytesPerRow * image.height }
}

enum ImageDecoder {
    /// Core Animation cannot show textures that are larger than this.
    static let maxDimension = 16_384
    static let thumbnailPixelSize = 384

    static func decodeFull(_ url: URL) -> DecodedImage? {
        guard let source = makeSource(url) else { return decodeWithAppKit(url) }
        let size = orientedPixelSize(of: source)
        let longest = Int(max(size.width, size.height))
        // The thumbnail API applies the EXIF orientation, which CGImageSourceCreateImageAtIndex does not.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest > 0 ? min(longest, maxDimension) : maxDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return decodeWithAppKit(url)
        }
        let animated = isAnimated(source) ? NSImage(contentsOf: url) : nil
        return DecodedImage(cgImage: image, animated: animated)
    }

    static func decodeThumbnail(_ url: URL, maxPixelSize: Int = thumbnailPixelSize) -> Thumbnail? {
        guard let source = makeSource(url) else {
            if VideoDecoder.isVideo(url) { return VideoDecoder.thumbnail(url, maxPixelSize: maxPixelSize) }
            if DocumentDecoder.isDocument(url) { return DocumentDecoder.thumbnail(url, maxPixelSize: maxPixelSize) }
            guard let decoded = decodeWithAppKit(url) else { return nil }
            return Thumbnail(image: decoded.cgImage, fullPixelSize: decoded.pixelSize)
        }
        let size = orientedPixelSize(of: source)
        // RAW files contain a large embedded preview. A full RAW decode is much slower.
        let isRaw = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }?.conforms(to: .rawImage) ?? false
        let options: [CFString: Any] = [
            isRaw ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let fullSize = size == .zero ? CGSize(width: image.width, height: image.height) : size
        return Thumbnail(image: image, fullPixelSize: fullSize)
    }

    /// Rotates by quarter turns. Positive values turn clockwise.
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let width = image.width, height = image.height
        let (newWidth, newHeight) = turns % 2 == 0 ? (width, height) : (height, width)
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
        // Core Graphics has a y-up coordinate system, so a negative angle turns clockwise.
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2,
                                       width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }

    // MARK: - Helpers

    private static func makeSource(_ url: URL) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        return source
    }

    static func orientedPixelSize(of source: CGImageSource) -> CGSize {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return .zero
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // Orientations 5–8 rotate the image by 90°.
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    private static func isAnimated(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 1, let type = CGImageSourceGetType(source) as String? else {
            return false
        }
        return [UTType.gif, .png, .webP].contains { $0.identifier == type }
    }

    /// For formats that ImageIO cannot read, such as SVG.
    private static func decodeWithAppKit(_ url: URL) -> DecodedImage? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(4, max(1, 2048 / longest))
        var rect = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return DecodedImage(cgImage: cgImage, animated: nil)
    }
}
