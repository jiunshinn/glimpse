import AppKit

/// Remembers the files of a drag that started in Glimpse.
/// A tab uses it to ignore a drop of its own files, and to not show the drop highlight for them.
@MainActor
enum OutgoingDrag {
    private(set) static var urls: [URL] = []
    private static var observer: NSObjectProtocol?

    static func begin(_ urls: [URL]) {
        self.urls = urls
        // A drag that a SwiftUI view starts does not tell when it ends.
        // A drag from another app makes Glimpse inactive first, so forget the files then.
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { OutgoingDrag.end() }
            }
        }
    }

    static func end() {
        urls = []
    }

    /// True while the mouse button is down for a drag that started in Glimpse.
    static var isActive: Bool {
        !urls.isEmpty && NSEvent.pressedMouseButtons & 1 != 0
    }

    /// True if the dropped files are the files of the drag that started in Glimpse.
    static func carries(_ dropped: [URL]) -> Bool {
        !urls.isEmpty && dropped.count == urls.count
            && zip(dropped, urls).allSatisfy { $0.isSameFile(as: $1) }
    }

    /// A drag item for a file. Finder copies the file, and other apps get the file.
    static func itemProvider(for url: URL) -> NSItemProvider {
        begin([url])
        return NSItemProvider(object: url as NSURL)
    }
}
