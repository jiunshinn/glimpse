import AVFoundation
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
    static func load(_ url: URL) async -> ImageInfo {
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey, .contentTypeKey,
        ])
        if let type = values?.contentType, VideoDecoder.isPlayable(type) {
            return await loadVideo(url, values: values)
        }
        return loadImage(url, values: values)
    }

    // MARK: - Images

    private static func loadImage(_ url: URL, values: URLResourceValues?) -> ImageInfo {
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
        image += kindAndSizeRows(values)
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
        if let name = cameraName(make: tiff[kCGImagePropertyTIFFMake] as? String, model: tiff[kCGImagePropertyTIFFModel] as? String) {
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
        let taken = (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(parseExifDate)
        sections.append(fileSection(url, values: values, taken: taken, software: tiff[kCGImagePropertyTIFFSoftware] as? String))

        // Location
        var coordinate: ImageInfo.Coordinate?
        if var latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           var longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }
            let found = ImageInfo.Coordinate(latitude: latitude, longitude: longitude)
            coordinate = found
            sections.append(locationSection(found, altitude: gps[kCGImagePropertyGPSAltitude] as? Double))
        }

        return ImageInfo(url: url, sections: sections, coordinate: coordinate)
    }

    // MARK: - Videos

    private static func loadVideo(_ url: URL, values: URLResourceValues?) async -> ImageInfo {
        let asset = AVURLAsset(url: url)
        var sections: [ImageInfo.Section] = []

        // Video
        var video: [ImageInfo.Row] = []
        if let size = await VideoDecoder.displaySize(of: asset) {
            video.append(.init(label: "Dimensions", value: "\(Int(size.width)) × \(Int(size.height))"))
        }
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            video.append(.init(label: "Duration", value: formatDuration(duration.seconds)))
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let loaded = try? await track.load(.nominalFrameRate, .formatDescriptions, .mediaCharacteristics, .estimatedDataRate) {
            let (frameRate, formats, characteristics, dataRate) = loaded
            if frameRate > 0 {
                let rounded = (Double(frameRate) * 100).rounded() / 100
                video.append(.init(label: "Frame Rate", value: "\(formatNumber(rounded, decimals: 2)) fps"))
            }
            if let format = formats.first {
                var codec = codecName(CMFormatDescriptionGetMediaSubType(format))
                if characteristics.contains(.containsHDRVideo) { codec += " · HDR" }
                video.append(.init(label: "Codec", value: codec))
            }
            if dataRate > 0 {
                video.append(.init(label: "Bit Rate", value: "\(formatNumber(Double(dataRate) / 1_000_000)) Mbps"))
            }
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let format = (try? await track.load(.formatDescriptions))?.first {
            var audio = [codecName(CMFormatDescriptionGetMediaSubType(format))]
            if let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                switch stream.mChannelsPerFrame {
                case 0: break
                case 1: audio.append("Mono")
                case 2: audio.append("Stereo")
                case let channels: audio.append("\(channels) channels")
                }
                if stream.mSampleRate > 0 { audio.append("\(formatNumber(stream.mSampleRate / 1000)) kHz") }
            }
            video.append(.init(label: "Audio", value: audio.joined(separator: " · ")))
        }
        video += kindAndSizeRows(values)
        sections.append(.init(title: "Video", rows: video))

        // Camera, date and place, as phones and cameras record them
        // The items keep their own identifiers (for example "mdta/com.apple.quicktime.make"), so match the common key.
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        func string(_ key: AVMetadataKey) async -> String? {
            guard let item = metadata.first(where: { $0.commonKey == key }) else { return nil }
            return try? await item.load(.stringValue)
        }
        if let name = cameraName(make: await string(.commonKeyMake), model: await string(.commonKeyModel)) {
            sections.append(.init(title: "Camera", rows: [.init(label: "Camera", value: name)]))
        }

        var taken: Date?
        if let item = try? await asset.load(.creationDate) {
            taken = try? await item.load(.dateValue)
        }
        sections.append(fileSection(url, values: values, taken: taken, software: await string(.commonKeySoftware)))

        var coordinate: ImageInfo.Coordinate?
        if let location = await string(.commonKeyLocation), let parsed = parseISO6709(location) {
            coordinate = parsed.coordinate
            sections.append(locationSection(parsed.coordinate, altitude: parsed.altitude))
        }

        return ImageInfo(url: url, sections: sections, coordinate: coordinate)
    }

    // MARK: - Shared sections

    private static func kindAndSizeRows(_ values: URLResourceValues?) -> [ImageInfo.Row] {
        var rows: [ImageInfo.Row] = []
        if let kind = values?.localizedTypeDescription { rows.append(.init(label: "Kind", value: kind)) }
        if let size = values?.fileSize {
            rows.append(.init(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        return rows
    }

    private static func cameraName(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces)
        guard let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        return make.map { model.localizedCaseInsensitiveContains($0) ? model : "\($0) \(model)" } ?? model
    }

    private static func fileSection(_ url: URL, values: URLResourceValues?, taken: Date?, software: String?) -> ImageInfo.Section {
        var file: [ImageInfo.Row] = []
        if let taken {
            file.append(.init(label: "Taken", value: taken.formatted(date: .abbreviated, time: .shortened)))
        }
        if let created = values?.creationDate {
            file.append(.init(label: "Created", value: created.formatted(date: .abbreviated, time: .shortened)))
        }
        if let modified = values?.contentModificationDate {
            file.append(.init(label: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened)))
        }
        if let software {
            file.append(.init(label: "Software", value: software))
        }
        let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        file.append(.init(label: "Folder", value: folder))
        return .init(title: "File", rows: file)
    }

    private static func locationSection(_ coordinate: ImageInfo.Coordinate, altitude: Double?) -> ImageInfo.Section {
        var rows: [ImageInfo.Row] = [
            .init(label: "Coordinates", value: String(format: "%.5f°, %.5f°", coordinate.latitude, coordinate.longitude)),
        ]
        if let altitude {
            rows.append(.init(label: "Altitude", value: "\(Int(altitude.rounded())) m"))
        }
        return .init(title: "Location", rows: rows)
    }

    // MARK: - Formatting

    private static func formatNumber(_ value: Double, decimals: Int = 1) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.\(decimals)f", value)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds.rounded()).formatted(.time(pattern: pattern))
    }

    private static func parseExifDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: string)
    }

    /// Reads a location such as "+37.3349-122.0090+030.000/" (ISO 6709), as phones write it into videos.
    private static func parseISO6709(_ string: String) -> (coordinate: ImageInfo.Coordinate, altitude: Double?)? {
        guard let match = string.prefixMatch(of: #/([+-][0-9.]+)([+-][0-9.]+)([+-][0-9.]+)?/#),
              let latitude = Double(match.1), let longitude = Double(match.2)
        else { return nil }
        return (.init(latitude: latitude, longitude: longitude), match.3.flatMap { Double($0) })
    }

    /// Names a codec from its four-character code, for example "hvc1" → "HEVC".
    private static func codecName(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let fourCC = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        switch fourCC {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "dvh1", "dvhe": return "HEVC (Dolby Vision)"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": return "ProRes"
        case "mp4v": return "MPEG-4"
        case "jpeg": return "Motion JPEG"
        case "aac": return "AAC"
        case "alac": return "Apple Lossless"
        case "lpcm": return "PCM"
        case ".mp3": return "MP3"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        case "opus": return "Opus"
        case "flac": return "FLAC"
        default: return fourCC
        }
    }
}
