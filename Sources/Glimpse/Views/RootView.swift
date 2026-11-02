import SwiftUI

struct RootView: View {
    let model: ViewerModel
    @State private var isDropTargeted = false
    /// What a drop does, when a file from another tab goes into the folder of this tab.
    @State private var dropLabel: String?

    var body: some View {
        ZStack {
            Color.black

            if model.ambientBackground && !model.isGridMode {
                AmbientBackdrop(image: model.ambientImage, key: model.ambientKey)
            }

            CanvasRepresentable(model: model)
                .opacity(model.isGridMode ? 0 : 1)
                .allowsHitTesting(!model.isGridMode)

            if model.showsVideo && !model.loadFailed {
                VideoStage(model: model)
            }

            // The document stays open under the grid, so it keeps its page.
            if model.document != nil && !model.loadFailed {
                DocumentStage(model: model)
                    .opacity(model.isGridMode ? 0 : 1)
                    .allowsHitTesting(!model.isGridMode)
            }

            if model.isGridMode && model.hasItems {
                GridView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if !model.hasItems {
                EmptyStateView(model: model, isDropTargeted: isDropTargeted)
                    .transition(.opacity)
            } else if model.loadFailed && !model.isGridMode {
                LoadFailedView(name: model.current?.name ?? "")
            }

            EdgeNavigationView(model: model)
            chrome
            ToastLayer(model: model)

            if model.showShortcuts {
                ShortcutsOverlay { model.showShortcuts = false }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if isDropTargeted && model.hasItems {
                DropHighlight(label: dropLabel)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
        } isTargeted: { targeted in
            // Do not offer to open the files of a drag that started in this tab.
            let isOwn = OutgoingDrag.isActive
            isDropTargeted = targeted && !(isOwn && model.containsAll(OutgoingDrag.urls))
            dropLabel = nil
            if isDropTargeted, isOwn, let folder = model.dropFolder {
                let name = FileManager.default.displayName(atPath: folder.path)
                dropLabel = FileMover.mode(for: OutgoingDrag.urls, into: folder) == .move
                    ? "Move to \(name) · ⌥ copies" : "Copy to \(name)"
            }
        }
        .animation(.smooth(duration: 0.28), value: model.isGridMode)
        .animation(.smooth(duration: 0.28), value: model.showInfo)
        .animation(.smooth(duration: 0.28), value: model.filmstripVisible)
        .animation(.smooth(duration: 0.22), value: model.showShortcuts)
        .animation(.smooth(duration: 0.22), value: model.hasItems)
    }

    private var chrome: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if model.filmstripVisible {
                    FilmstripView(model: model)
                        .padding(.horizontal, 24)
                        .padding(.bottom, Layout.filmstripBottomMargin)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)

            if model.showInfo {
                InfoPanel(model: model)
                    .padding(.top, model.topInset + Layout.panelMargin)
                    .padding(.bottom, Layout.panelMargin)
                    .padding(.trailing, Layout.panelMargin)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

/// A blurred copy of the current image that fills the window behind it.
struct AmbientBackdrop: View {
    let image: CGImage?
    let key: URL?

    var body: some View {
        ZStack {
            if let image {
                GeometryReader { proxy in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
                .blur(radius: 70, opaque: true)
                .saturation(1.25)
                .opacity(0.5)
                .id(key)
                .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.45), value: key)
        .allowsHitTesting(false)
    }
}

struct DropHighlight: View {
    var label: String?

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if let label {
                    Label(label, systemImage: "folder")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .glassSurface(Capsule())
                }
            }
            .padding(10)
            .allowsHitTesting(false)
    }
}

struct LoadFailedView: View {
    let name: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Glimpse can’t open “\(name)”")
                .font(.headline)
            Text("The file may be damaged, or its format is not supported.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .allowsHitTesting(false)
    }
}
