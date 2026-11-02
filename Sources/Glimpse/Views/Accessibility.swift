import AppKit
import SwiftUI

/// VoiceOver announcements, the text that VoiceOver reads for files, and the system display settings.
@MainActor
enum Accessibility {
    static var isVoiceOverOn: Bool { NSWorkspace.shared.isVoiceOverEnabled }

    /// Reduce Motion in System Settings. SwiftUI views read `accessibilityReduceMotion` from the environment instead.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Speaks the text with VoiceOver. VoiceOver does not move its cursor for an announcement.
    static func announce(_ text: String, priority: NSAccessibilityPriorityLevel = .high) {
        guard isVoiceOverOn, !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }

    /// For example "JPEG image" or "MP4 video".
    static func kindDescription(_ item: ImageItem) -> String {
        let kind: String
        switch item.kind {
        case .image: kind = "image"
        case .video: kind = "video"
        case .document: kind = "document"
        }
        return item.format == "Other" ? kind : "\(item.format) \(kind)"
    }

    /// For example "JPEG image, pinned, starred, tags: Keep, Client, new".
    static func fileValue(_ item: ImageItem, marks: FileMarks) -> String {
        var parts = [kindDescription(item)]
        if marks.isPinned { parts.append("pinned") }
        if marks.isStarred { parts.append("starred") }
        if !marks.tags.isEmpty { parts.append("tags: " + marks.tags.map(\.name).joined(separator: ", ")) }
        if marks.isNew { parts.append("new") }
        return parts.joined(separator: ", ")
    }
}

extension AnyTransition {
    /// The transition, or only a fade when Reduce Motion is on.
    static func motion(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }
}

extension View {
    /// VoiceOver reads a file as one element, with actions for the commands of its context menu.
    func fileAccessibility(_ item: ImageItem, marks: FileMarks, isSelected: Bool, model: ViewerModel,
                           activate: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityValue(Accessibility.fileValue(item, marks: marks))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, activate)
            .accessibilityAction(named: marks.isStarred ? "Remove Star" : "Star") { model.toggleStar(item.url) }
            .accessibilityAction(named: marks.isPinned ? "Unpin from Top" : "Pin to Top") { model.toggleFilePin(item.url) }
            .accessibilityAction(named: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
    }

    /// Reports to the model that a control in the viewer has the keyboard focus (Full Keyboard Access).
    /// The window then lets Space, Return and the arrow keys go to the control.
    func reportsKeyboardFocus(to model: ViewerModel) -> some View {
        modifier(KeyboardFocusReporter(model: model))
    }
}

private struct KeyboardFocusReporter: ViewModifier {
    let model: ViewerModel
    @FocusState private var isFocused: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in model.setControlFocus(focused, id: id) }
            .onDisappear { model.setControlFocus(false, id: id) }
    }
}
