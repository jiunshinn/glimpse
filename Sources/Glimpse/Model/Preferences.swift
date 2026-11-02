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

    static var windowFrame: NSRect? {
        get { defaults.string(forKey: "windowFrame").map(NSRectFromString).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue.map(NSStringFromRect), forKey: "windowFrame") }
    }
}
