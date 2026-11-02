import SwiftUI

/// Loads and shows the thumbnail of a file.
struct ThumbnailImage: View {
    let url: URL
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 0

    @State private var thumbnail: CGImage?
    @State private var loadedURL: URL?

    init(url: URL, contentMode: ContentMode = .fill, cornerRadius: CGFloat = 0) {
        self.url = url
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        // Use a cached thumbnail at once, so scrolling back does not flash.
        let cached = ImagePipeline.shared.cachedThumbnail(for: url)?.image
        _thumbnail = State(initialValue: cached)
        _loadedURL = State(initialValue: cached == nil ? nil : url)
    }

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .clipShape(RoundedRectangle(cornerRadius: contentMode == .fit ? cornerRadius : 0, style: .continuous))
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .aspectRatio(contentMode == .fit ? 4.0 / 3.0 : nil, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            guard loadedURL != url else { return }
            if let cached = ImagePipeline.shared.cachedThumbnail(for: url) {
                thumbnail = cached.image
                loadedURL = url
                return
            }
            thumbnail = nil
            let loaded = await ImagePipeline.shared.thumbnail(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                thumbnail = loaded?.image
            }
            loadedURL = url
        }
    }
}
