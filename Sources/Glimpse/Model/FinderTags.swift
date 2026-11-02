import Foundation

/// A Finder tag: a name and one of the Finder tag colors.
struct FinderTag: Hashable, Sendable {
    let name: String
    /// The Finder color number: 0 none, 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange.
    let color: Int

    /// The tags that the keys 1 to 5 add and remove.
    static let quickTags: [FinderTag] = [
        FinderTag(name: "Keep", color: 2),
        FinderTag(name: "Edit", color: 7),
        FinderTag(name: "Client", color: 4),
        FinderTag(name: "Print", color: 3),
        FinderTag(name: "Reject", color: 6),
    ]
}

/// Reads and writes Finder tags. Finder and Spotlight show the same tags.
enum FinderTags {
    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    static func read(_ url: URL) -> [FinderTag] {
        let path = url.path
        let size = getxattr(path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, 0) }
        guard count == size,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return list.map(parse)
    }

    /// Returns false if the file cannot get the tags, for example on a read-only volume.
    @discardableResult
    static func write(_ tags: [FinderTag], to url: URL) -> Bool {
        let path = url.path
        guard !tags.isEmpty else {
            return removexattr(path, attribute, 0) == 0 || errno == ENOATTR
        }
        // Finder keeps the color after the name, on a second line.
        let list = tags.map { $0.color == 0 ? $0.name : "\($0.name)\n\($0.color)" }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else {
            return false
        }
        return data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, data.count, 0, 0) } == 0
    }

    private static func parse(_ entry: String) -> FinderTag {
        let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let color = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return FinderTag(name: String(parts.first ?? ""), color: color)
    }
}
