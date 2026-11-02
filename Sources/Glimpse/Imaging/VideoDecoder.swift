import AVFoundation
import UniformTypeIdentifiers

/// Reads video files with AVFoundation.
enum VideoDecoder {
    /// The video types that AVFoundation can open on this Mac (MOV, MP4, M4V, 3GP and more).
    static let playableTypes: [UTType] = AVURLAsset.audiovisualTypes()
        .compactMap { UTType($0.rawValue) }
        .filter { $0.conforms(to: .movie) }

    static func isPlayable(_ type: UTType) -> Bool {
        type.conforms(to: .movie) && playableTypes.contains { type.conforms(to: $0) }
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return isPlayable(type)
    }

    /// A frame near the start, plus the display size and the duration of the video.
    /// It blocks the thread until AVFoundation is done, so call it only from an operation queue.
    static func thumbnail(_ url: URL, maxPixelSize: Int) -> Thumbnail? {
        waitFor {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  let size = await displaySize(of: asset)
            else { return nil }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            // The first frame is often black, so take a frame a little later.
            let seconds = duration.isNumeric ? min(1, duration.seconds / 4) : 0
            guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            else { return nil }
            return Thumbnail(image: frame, fullPixelSize: size, duration: duration.isNumeric ? duration.seconds : nil)
        }
    }

    /// The size of the video track after its rotation, or nil if the file has no video track.
    static func displaySize(of asset: AVAsset) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let size = loaded.0.applying(loaded.1)
        guard size.width != 0, size.height != 0 else { return nil }
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    // MARK: - Helpers

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    /// Runs async work and waits for its result. Operation queue threads are not part of
    /// the Swift concurrency thread pool, so the wait does not block other tasks.
    private static func waitFor<T>(_ work: @escaping @Sendable () async -> T?) -> T? {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.value = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }
}
