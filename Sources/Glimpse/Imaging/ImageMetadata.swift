import Foundation
import ImageIO

struct ImageInfo: Sendable {
    struct Row: Identifiable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }

    struct Section: Identifiable, Sendable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    struct Coordinate: Sendable {
        let latitude: Double
        let longitude: Double
    }

    let url: URL
    let sections: [Section]
    let coordinate: Coordinate?
}

enum ImageMetadata {
    static func load(_ url: URL) -> ImageInfo {
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey,
        ])
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        var sections: [ImageInfo.Section] = []

        // Image
        var image: [ImageInfo.Row] = []
        if let source {
            let size = ImageDecoder.orientedPixelSize(of: source)
            if size.width > 0 {
                let megapixels = size.width * size.height / 1_000_000
                image.append(.init(label: "Dimensions",
                                   value: "\(Int(size.width)) × \(Int(size.height))  ·  \(String(format: "%.1f", megapixels)) MP"))
            }
            let frames = CGImageSourceGetCount(source)
            if frames > 1 { image.append(.init(label: "Frames", value: "\(frames)")) }
        }
        if let kind = values?.localizedTypeDescription { image.append(.init(label: "Kind", value: kind)) }
        if let size = values?.fileSize {
            image.append(.init(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        var color: [String] = []
        if let model = properties[kCGImagePropertyColorModel] as? String { color.append(model) }
        if let depth = properties[kCGImagePropertyDepth] as? Int { color.append("\(depth)-bit") }
        if !color.isEmpty { image.append(.init(label: "Color", value: color.joined(separator: " · "))) }
        if let profile = properties[kCGImagePropertyProfileName] as? String {
            image.append(.init(label: "Profile", value: profile))
        }
        if let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 0 {
            image.append(.init(label: "Resolution", value: "\(Int(dpi.rounded())) dpi"))
        }
        sections.append(.init(title: "Image", rows: image))

        // Camera
        var camera: [ImageInfo.Row] = []
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model {
            let name = make.map { model.localizedCaseInsensitiveContains($0) ? model : "\($0) \(model)" } ?? model
            camera.append(.init(label: "Camera", value: name))
        }
        if let lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? (exifAux[kCGImagePropertyExifAuxLensModel] as? String) {
            camera.append(.init(label: "Lens", value: lens))
        }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            var value = "\(formatNumber(focal)) mm"
            if let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, equivalent > 0,
               abs(Double(equivalent) - focal) > 0.5 {
                value += "  (\(equivalent) mm equiv.)"
            }
            camera.append(.init(label: "Focal Length", value: value))
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double {
            camera.append(.init(label: "Aperture", value: "ƒ/\(formatNumber(aperture))"))
        }
        if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
            let value = exposure < 1 ? "1/\(Int((1 / exposure).rounded())) s" : "\(formatNumber(exposure)) s"
            camera.append(.init(label: "Shutter", value: value))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
            camera.append(.init(label: "ISO", value: "\(iso)"))
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, abs(bias) > 0.01 {
            camera.append(.init(label: "Exposure", value: String(format: "%+.1f EV", bias)))
        }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int {
            camera.append(.init(label: "Flash", value: flash & 1 == 1 ? "Fired" : "Off"))
        }
        if !camera.isEmpty { sections.append(.init(title: "Camera", rows: camera)) }

        // File
        var file: [ImageInfo.Row] = []
        if let taken = (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(parseExifDate) {
            file.append(.init(label: "Taken", value: taken.formatted(date: .abbreviated, time: .shortened)))
        }
        if let created = values?.creationDate {
            file.append(.init(label: "Created", value: created.formatted(date: .abbreviated, time: .shortened)))
        }
        if let modified = values?.contentModificationDate {
            file.append(.init(label: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened)))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String {
            file.append(.init(label: "Software", value: software))
        }
        let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        file.append(.init(label: "Folder", value: folder))
        sections.append(.init(title: "File", rows: file))

        // Location
        var coordinate: ImageInfo.Coordinate?
        if var latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           var longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }
            coordinate = .init(latitude: latitude, longitude: longitude)
            var rows: [ImageInfo.Row] = [
                .init(label: "Coordinates", value: String(format: "%.5f°, %.5f°", latitude, longitude)),
            ]
            if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
                rows.append(.init(label: "Altitude", value: "\(Int(altitude.rounded())) m"))
            }
            sections.append(.init(title: "Location", rows: rows))
        }

        return ImageInfo(url: url, sections: sections, coordinate: coordinate)
    }

    private static func formatNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func parseExifDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: string)
    }
}
