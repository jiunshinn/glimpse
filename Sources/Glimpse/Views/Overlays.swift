import SwiftUI

/// Round previous/next buttons that appear when the pointer is near the left or right edge.
struct EdgeNavigationView: View {
    let model: ViewerModel

    var body: some View {
        let insets = model.canvasInsets
        HStack {
            if model.hoverEdge == .leading && model.index > 0 {
                NavigationButton(symbol: "chevron.left", help: "Previous (←)") { model.previous() }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Spacer(minLength: 0)
            if model.hoverEdge == .trailing && model.index < model.items.count - 1 {
                NavigationButton(symbol: "chevron.right", help: "Next (→)") { model.next() }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, insets.top)
        .padding(.bottom, insets.bottom)
        .padding(.trailing, insets.right)
        .animation(.smooth(duration: 0.2), value: model.hoverEdge)
    }
}

private struct NavigationButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(Circle(), interactive: true)
        .help(help)
    }
}

struct ToastLayer: View {
    let model: ViewerModel

    var body: some View {
        VStack {
            if let toast = model.toast {
                HStack(spacing: 8) {
                    if let symbol = toast.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(toast.message)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassSurface(Capsule())
                .id(toast.id)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
            Spacer()
        }
        .padding(.top, model.topInset + 14)
        .padding(.trailing, model.canvasInsets.right)
        .animation(.smooth(duration: 0.2), value: model.toast)
        .allowsHitTesting(false)
    }
}

struct ShortcutsOverlay: View {
    let dismiss: () -> Void

    private let groups: [(String, [(String, String)])] = [
        ("Browse", [
            ("← →", "Previous / next image"),
            ("Space", "Next image (⇧ for previous)"),
            ("Home End", "First / last image"),
            ("G", "Grid of the whole folder"),
            ("Return", "Open the selected image (grid)"),
            ("Swipe", "Two fingers left or right"),
        ]),
        ("View", [
            ("+ −", "Zoom in / out"),
            ("Z", "Fit ↔ close-up (or double-click)"),
            ("⌘0  ⌘9", "Actual size / zoom to fit"),
            ("⌥ Scroll", "Zoom at the pointer"),
            ("R", "Rotate (⇧ for left)"),
            ("F", "Full screen"),
        ]),
        ("Panels", [
            ("I", "Info and EXIF"),
            ("T", "Thumbnails"),
            ("Esc", "Back / exit full screen"),
        ]),
        ("File", [
            ("⌘⌫", "Move to Trash (⌘Z to undo)"),
            ("⌘C", "Copy image"),
            ("⇧⌘R", "Show in Finder"),
        ]),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    KeyCap("?")
                }
                Grid(alignment: .topLeading, horizontalSpacing: 36, verticalSpacing: 20) {
                    GridRow {
                        group(0)
                        group(1)
                    }
                    GridRow {
                        group(2)
                        group(3)
                    }
                }
            }
            .padding(26)
            .frame(width: 640)
            .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    private func group(_ index: Int) -> some View {
        let (title, rows) = groups[index]
        return VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            ForEach(rows, id: \.0) { key, description in
                HStack(spacing: 10) {
                    Text(key)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .frame(width: 70, alignment: .leading)
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
