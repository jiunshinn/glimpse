import SwiftUI

/// How a thumbnail marks a video.
enum VideoBadge {
    /// A play symbol only, for small thumbnails.
    case symbol
    /// A play symbol and the duration.
    case duration
}

/// Loads and shows the thumbnail of a file.
struct ThumbnailImage: View {
    let url: URL
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 0
    var videoBadge: VideoBadge = .symbol

    @State private var thumbnail: Thumbnail?
    @State private var loadedURL: URL?

    init(url: URL, contentMode: ContentMode = .fill, cornerRadius: CGFloat = 0, videoBadge: VideoBadge = .symbol) {
        self.url = url
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.videoBadge = videoBadge
        // Use a cached thumbnail at once, so scrolling back does not flash.
        let cached = ImagePipeline.shared.cachedThumbnail(for: url)
        _thumbnail = State(initialValue: cached)
        _loadedURL = State(initialValue: cached == nil ? nil : url)
    }

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .clipShape(RoundedRectangle(cornerRadius: contentMode == .fit ? cornerRadius : 0, style: .continuous))
                    // A fitted image can be smaller than the frame. Put the badge on the corner of the image.
                    .overlay(alignment: .bottomTrailing) {
                        if contentMode == .fit { badge }
                    }
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .aspectRatio(contentMode == .fit ? 4.0 / 3.0 : nil, contentMode: .fit)
            }
        }
        // The zero minimums keep the frame at the offered size. Without them, a filled image makes the frame larger.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // A filled image overflows the frame. Put the badge on the corner of the frame.
        .overlay(alignment: .bottomTrailing) {
            if contentMode == .fill { badge }
        }
        .task(id: url) {
            guard loadedURL != url else { return }
            if let cached = ImagePipeline.shared.cachedThumbnail(for: url) {
                thumbnail = cached
                loadedURL = url
                return
            }
            thumbnail = nil
            let loaded = await ImagePipeline.shared.thumbnail(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                thumbnail = loaded
            }
            loadedURL = url
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let duration = thumbnail?.duration {
            switch videoBadge {
            case .symbol:
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 2)
                    .padding(5)
            case .duration:
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 7, weight: .bold))
                    Text(ImageMetadata.formatDuration(duration))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(5)
            }
        }
    }
}
