import AppKit

/// Moves or copies dropped files into a folder, as Finder does.
@MainActor
enum FileMover {
    enum Mode {
        case move, copy

        var past: String { self == .move ? "Moved" : "Copied" }
    }

    struct Result {
        let mode: Mode
        /// The files that Glimpse moved or copied, and where they are now.
        let done: [(from: URL, to: URL)]
        let failed: Int
    }

    /// Finder moves a file on the same disk and copies a file to another disk. ⌥ always copies.
    static func mode(for urls: [URL], into folder: URL) -> Mode {
        if NSEvent.modifierFlags.contains(.option) { return .copy }
        // A file from a phone stays on the phone: it is copied, never moved out of the cache.
        if urls.contains(where: DeviceLibrary.isCacheItem) { return .copy }
        let target = volume(of: folder)
        return urls.allSatisfy { volume(of: $0)?.isEqual(target) ?? false } ? .move : .copy
    }

    /// Moves or copies the files into the folder. A file that is in the folder already stays as it is.
    /// A file with the same name as a file in the folder gets a number, for example "photo 2.jpg".
    /// ⌘Z puts the moved files back, or moves the copies to the Trash.
    static func transfer(_ urls: [URL], into folder: URL, mode: Mode, undoManager: UndoManager?) -> Result {
        let manager = FileManager.default
        var done: [(from: URL, to: URL)] = []
        var failed = 0
        for url in urls where !url.deletingLastPathComponent().isSameFile(as: folder) {
            let destination = freeURL(for: url.lastPathComponent, in: folder)
            do {
                if mode == .move {
                    try manager.moveItem(at: url, to: destination)
                    Workspace.shared.fileMoved(from: url, to: destination)
                } else {
                    try manager.copyItem(at: url, to: destination)
                }
                done.append((url, destination))
            } catch {
                failed += 1
            }
        }
        if !done.isEmpty, let undoManager {
            undoManager.registerUndo(withTarget: NSApp) { _ in
                MainActor.assumeIsolated { undo(done, mode: mode, folder: folder, undoManager: undoManager) }
            }
            undoManager.setActionName(mode == .move ? "Move" : "Copy")
        }
        return Result(mode: mode, done: done, failed: failed)
    }

    private static func undo(_ done: [(from: URL, to: URL)], mode: Mode, folder: URL, undoManager: UndoManager) {
        let manager = FileManager.default
        for (from, to) in done {
            if mode == .move {
                guard !manager.fileExists(atPath: from.path), (try? manager.moveItem(at: to, to: from)) != nil else { continue }
                Workspace.shared.fileMoved(from: to, to: from)
            } else {
                try? manager.trashItem(at: to, resultingItemURL: nil)
            }
        }
        undoManager.registerUndo(withTarget: NSApp) { _ in
            MainActor.assumeIsolated {
                _ = transfer(done.map(\.from), into: folder, mode: mode, undoManager: undoManager)
            }
        }
        undoManager.setActionName(mode == .move ? "Move" : "Copy")
    }

    private static func volume(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    private static func freeURL(for name: String, in folder: URL) -> URL {
        let manager = FileManager.default
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while manager.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return url
    }
}
