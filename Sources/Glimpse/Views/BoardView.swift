import AppKit
import SwiftUI

/// A free canvas. The files on it come from different folders. Drag an item to move it, and drag its corner to resize it.
struct BoardView: View {
    let boardID: UUID
    let tab: TabState
    let topInset: CGFloat

    /// The item that moves or changes size now, and by how much.
    @State private var drag: (id: UUID, offset: CGSize)?
    @State private var resize: (id: UUID, width: CGFloat)?
    @FocusState private var focusedNote: UUID?

    private var workspace: Workspace { .shared }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(white: 0.05)
                if let board = workspace.board(boardID) {
                    canvas(board, viewport: proxy.size)
                    if board.items.isEmpty { emptyState }
                }
            }
            .onAppear { tab.boardViewportWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, width in tab.boardViewportWidth = width }
        }
        .onChange(of: tab.focusedNote) { _, id in
            guard let id else { return }
            focusedNote = id
            tab.focusedNote = nil
        }
    }

    private func canvas(_ board: Board, viewport: CGSize) -> some View {
        let width = max(viewport.width, (board.items.map { $0.x + $0.width }.max() ?? 0) + 80)
        let height = max(viewport.height - topInset, (board.items.map { $0.y + $0.height }.max() ?? 0) + 120)
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                DotGrid()
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
                    .onTapGesture { tab.boardSelection = nil }

                ForEach(board.items) { item in
                    itemView(item)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .dropDestination(for: URL.self) { urls, location in
                let files = urls.filter(FolderScanner.canOpen)
                guard !files.isEmpty else { return false }
                workspace.add(files, to: boardID, at: CGPoint(x: location.x - 60, y: location.y - 40))
                return true
            }
            .padding(.top, topInset)
        }
        .scrollIndicators(.automatic)
    }

    @ViewBuilder
    private func itemView(_ item: BoardItem) -> some View {
        let isSelected = tab.boardSelection == item.id
        let offset = drag?.id == item.id ? drag!.offset : .zero
        let width = resize?.id == item.id ? resize!.width : item.width
        Group {
            if item.isNote {
                note(item, width: width, isSelected: isSelected)
            } else {
                BoardFileView(item: item, width: width, isSelected: isSelected, boardID: boardID)
                    .gesture(moveGesture(item))
                    .onTapGesture(count: 2) { if let url = item.url { tab.controller?.openFromBoard(url) } }
                    .simultaneousGesture(TapGesture().onEnded { select(item) })
                    .contextMenu {
                        if let url = item.url {
                            Button("Open") { tab.controller?.openFromBoard(url) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Divider()
                        }
                        Button("Remove from Board") { workspace.removeItem(item.id, from: boardID) }
                    }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                .frame(width: 14, height: 14)
                .offset(x: 6, y: 6)
                .opacity(isSelected ? 1 : 0)
                .gesture(resizeGesture(item))
                .help("Drag to resize")
        }
        .offset(x: item.x + offset.width, y: item.y + offset.height)
    }

    private func note(_ item: BoardItem, width: CGFloat, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The note moves with this bar. The text below it takes clicks for editing.
            Capsule()
                .fill(Color.black.opacity(0.18))
                .frame(width: 30, height: 4)
                .frame(maxWidth: .infinity, minHeight: 16)
                .contentShape(Rectangle())
                .gesture(moveGesture(item))
                .onTapGesture { select(item) }
            TextField("Note", text: noteText(item), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.23, green: 0.2, blue: 0.06))
                .focused($focusedNote, equals: item.id)
                .onChange(of: focusedNote) { _, id in if id == item.id { select(item) } }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(width: width, alignment: .leading)
        .frame(minHeight: 90, alignment: .top)
        .background(Color(red: 0.99, green: 0.94, blue: 0.68), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .environment(\.colorScheme, .light)
        .contextMenu {
            Button("Remove from Board") { workspace.removeItem(item.id, from: boardID) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)
            Text("This board is empty")
                .font(.system(size: 17, weight: .semibold))
            Text("Press B on a file to put it here, or drop files from Finder.\nThe files stay in their folders.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 18) {
                KeyHint(keys: ["B"], label: "Add the current file")
                KeyHint(keys: ["⌘K"], label: "Search")
            }
            .padding(.top, 6)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private func select(_ item: BoardItem) {
        tab.boardSelection = item.id
        workspace.bringToFront(item.id, in: boardID)
    }

    private func moveGesture(_ item: BoardItem) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil { select(item) }
                drag = (item.id, value.translation)
            }
            .onEnded { value in
                drag = nil
                workspace.updateItem(item.id, in: boardID) {
                    $0.x = max(0, $0.x + value.translation.width)
                    $0.y = max(0, $0.y + value.translation.height)
                }
            }
    }

    private func resizeGesture(_ item: BoardItem) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                resize = (item.id, Self.clampedWidth(item.width + value.translation.width))
            }
            .onEnded { value in
                resize = nil
                workspace.updateItem(item.id, in: boardID) {
                    $0.width = Self.clampedWidth($0.width + value.translation.width)
                }
            }
    }

    private static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, 90), 1_400)
    }

    private func noteText(_ item: BoardItem) -> Binding<String> {
        Binding {
            workspace.board(boardID)?.items.first { $0.id == item.id }?.note ?? ""
        } set: { text in
            workspace.updateItem(item.id, in: boardID) { $0.note = text }
        }
    }
}

/// A file on a board: a large preview, with its name under it.
private struct BoardFileView: View {
    let item: BoardItem
    let width: CGFloat
    let isSelected: Bool
    let boardID: UUID

    @State private var preview: Thumbnail?
    @State private var isMissing = false
    @State private var isHovered = false

    var body: some View {
        let aspect = preview.map { CGFloat($0.image.width) / CGFloat(max($0.image.height, 1)) }
            ?? CGFloat(item.aspect ?? 4.0 / 3.0)
        ZStack {
            if let preview {
                Image(decorative: preview.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle().fill(Color.white.opacity(0.06))
                if isMissing {
                    VStack(spacing: 6) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: 22, weight: .light))
                        Text("Glimpse can’t find this file")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: width / max(aspect, 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let duration = preview?.duration {
                Label(ImageMetadata.formatDuration(duration), systemImage: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.07), lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
        .overlay(alignment: .topLeading) {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .offset(y: width / max(aspect, 0.05) + 6)
                .opacity(isSelected || isHovered ? 1 : 0)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(item.path ?? "")
        .task(id: item.path) { await load() }
    }

    private var caption: String {
        guard let url = item.url else { return "" }
        return "\(url.lastPathComponent)  ·  \(QuickSearchModel.folderName(of: url))"
    }

    private func load() async {
        guard let url = item.url else { return }
        if let cached = ImagePipeline.shared.cachedPreview(for: url) {
            preview = cached
        } else if FileManager.default.fileExists(atPath: url.path) {
            preview = ImagePipeline.shared.cachedThumbnail(for: url)
            if let loaded = await ImagePipeline.shared.preview(for: url) { preview = loaded }
        } else {
            isMissing = true
            return
        }
        // Record the shape of the image, so that Arrange and the board size know the height.
        if let image = preview?.image, image.height > 0 {
            let aspect = Double(image.width) / Double(image.height)
            if abs((item.aspect ?? 0) - aspect) > 0.01 {
                let itemID = item.id
                Workspace.shared.updateItem(itemID, in: boardID) { $0.aspect = aspect }
            }
        }
    }
}

/// The dots on the board.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 22
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 2, height: 2))
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    context.fill(dot.offsetBy(dx: x, dy: y), with: .color(.white.opacity(0.09)))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}
