import Foundation

enum Preferences {
    private static var defaults: UserDefaults { .standard }

    static var showThumbnails: Bool {
        get { defaults.object(forKey: "showThumbnails") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showThumbnails") }
    }

    static var ambientBackground: Bool {
        get { defaults.object(forKey: "ambientBackground") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ambientBackground") }
    }

    static var sortKey: SortKey {
        get { SortKey(rawValue: defaults.integer(forKey: "sortKey")) ?? .name }
        set { defaults.set(newValue.rawValue, forKey: "sortKey") }
    }

    static var sortAscending: Bool {
        get { defaults.object(forKey: "sortAscending") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sortAscending") }
    }

    static var gridTileSize: Double {
        get { defaults.object(forKey: "gridTileSize") as? Double ?? 170 }
        set { defaults.set(newValue, forKey: "gridTileSize") }
    }

    static var showSidebar: Bool {
        get { defaults.object(forKey: "showSidebar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showSidebar") }
    }

    static var windowFrame: NSRect? {
        get { defaults.string(forKey: "windowFrame").map(NSRectFromString).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue.map(NSStringFromRect), forKey: "windowFrame") }
    }

    static var loopVideos: Bool {
        get { defaults.bool(forKey: "loopVideos") }
        set { defaults.set(newValue, forKey: "loopVideos") }
    }

    static var videoVolume: Float {
        get { defaults.object(forKey: "videoVolume") as? Float ?? 1 }
        set { defaults.set(newValue, forKey: "videoVolume") }
    }

    // MARK: - Playback positions

    /// Glimpse keeps the positions of the most recent videos only.
    private static let playbackPositionLimit = 200

    /// Where a long video stopped the last time, in seconds.
    static func playbackPosition(for url: URL) -> Double? {
        let entries = defaults.array(forKey: "playbackPositions") as? [[String: Any]] ?? []
        return entries.first { $0["path"] as? String == url.path }?["seconds"] as? Double
    }

    /// Records where a video stopped. Nil removes the record, so the video starts at the beginning.
    static func setPlaybackPosition(_ seconds: Double?, for url: URL) {
        var entries = defaults.array(forKey: "playbackPositions") as? [[String: Any]] ?? []
        entries.removeAll { $0["path"] as? String == url.path }
        if let seconds {
            // The newest record is first. The oldest records go when the list is full.
            entries.insert(["path": url.path, "seconds": seconds], at: 0)
            entries = Array(entries.prefix(playbackPositionLimit))
        }
        defaults.set(entries, forKey: "playbackPositions")
    }
}
