import AppKit
import SwiftUI

/// The Quick Search panel. ↑ ↓ choose a result, ↵ opens it, ⌘↵ opens it in a new tab, ⌥↵ puts it on the board.
struct QuickSearchView: View {
    @Bindable var search: QuickSearchModel
    let topInset: CGFloat

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture { search.hide() }

            VStack(spacing: 0) {
                field
                Divider().opacity(0.5)
                HStack(spacing: 0) {
                    resultList
                        .frame(maxWidth: .infinity)
                    Divider().opacity(0.5)
                    QuickSearchPreview(result: search.selected)
                        .frame(width: 250)
                }
                .frame(height: 380)
                Divider().opacity(0.5)
                footer
            }
            .frame(maxWidth: 740)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            .padding(.horizontal, 24)
            .padding(.top, topInset + 28)
        }
        .onAppear {
            // The field can take the focus only after the panel is in the window.
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }

    private var field: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($isFieldFocused)
            if let mode = modeLabel {
                Text(mode)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.3), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if search.results.isEmpty {
                    VStack(spacing: 8) {
                        Text("No results for “\(search.query)”")
                            .foregroundStyle(.secondary)
                        Text("Try type:video, tag:keep, in:drone or is:starred.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(search.groups) { group in
                            Text(group.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(group.results) { result in
                                let index = search.results.firstIndex { $0.id == result.id } ?? 0
                                QuickSearchRow(result: result, isSelected: index == search.selection)
                                    .id(result.id)
                                    .onTapGesture {
                                        search.selection = index
                                        search.activate(index, modifiers: NSEvent.modifierFlags)
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
            .scrollIndicators(.never)
            .onChange(of: search.selection) { _, _ in
                guard let id = search.selected?.id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("Workspace", systemImage: "square.stack.3d.up")
                .foregroundStyle(.secondary)
            Text("type:  tag:  in:  is:")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            ForEach(actions, id: \.0) { title, key in
                HStack(spacing: 6) {
                    Text(title)
                    KeyCap(key)
                }
                .foregroundStyle(title == actions.first?.0 ? .primary : .secondary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private var placeholder: String {
        switch search.mode {
        case .open: "Search files, folders, tags and commands"
        case .newTab: "Open in this tab: a folder, a tag, a board or a file"
        case .addToBoard: "Put a file on the board"
        }
    }

    private var modeLabel: String? {
        switch search.mode {
        case .open: nil
        case .newTab: "New Tab"
        case .addToBoard: "Add to Board"
        }
    }

    private var actions: [(String, String)] {
        guard let result = search.selected else { return [] }
        switch (result.kind, search.mode) {
        case (.file, .addToBoard): return [("Add to Board", "↵")]
        case (.file, .newTab): return [("Open", "↵"), ("Add to Board", "⌥↵")]
        case (.file, .open): return [("Open", "↵"), ("New Tab", "⌘↵"), ("Add to Board", "⌥↵")]
        case (.command, _): return [("Run", "↵")]
        case (_, .newTab): return [("Open", "↵")]
        default: return [("Open", "↵"), ("New Tab", "⌘↵")]
        }
    }
}

private struct QuickSearchRow: View {
    let result: QuickSearchModel.Result
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 28, height: 28)
            highlightedTitle
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(result.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            accessory
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.13 : isHovered ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        switch result.kind {
        case .file(let item):
            ThumbnailImage(url: item.url, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .folder:
            symbolTile("folder.fill", color: .accentColor)
        case .smart(.starred):
            symbolTile("star.fill", color: .yellow)
        case .smart(.tag(let name)):
            let color = Workspace.shared.knownTags.first { $0.name == name }?.displayColor ?? .gray
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(Circle().fill(color).frame(width: 11, height: 11))
        case .board:
            symbolTile("rectangle.3.group", color: .accentColor)
        case .command(let command):
            symbolTile(command.symbol, color: .primary)
        }
    }

    private func symbolTile(_ name: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(Image(systemName: name).font(.system(size: 13, weight: .medium)).foregroundStyle(color))
    }

    private var highlightedTitle: Text {
        let matches = Set(result.matches)
        var title = AttributedString()
        for (index, character) in result.title.enumerated() {
            var piece = AttributedString(String(character))
            if matches.contains(index) {
                piece.font = .system(size: 13, weight: .bold)
                piece.foregroundColor = .white
                piece.underlineStyle = .single
            } else {
                piece.font = .system(size: 13)
            }
            title += piece
        }
        return Text(title)
    }

    @ViewBuilder
    private var accessory: some View {
        if case .file(let item) = result.kind {
            let workspace = Workspace.shared
            HStack(spacing: 4) {
                ForEach(workspace.tags(for: item.url), id: \.name) { tag in
                    Circle().fill(tag.displayColor).frame(width: 8, height: 8)
                }
                if workspace.isStarred(item.url) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                }
            }
        } else if case .command = result.kind, !result.accessory.isEmpty {
            KeyCap(result.accessory)
        } else {
            Text(result.accessory)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The right side of Quick Search: a preview and the details of the selected result.
private struct QuickSearchPreview: View {
    let result: QuickSearchModel.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result {
                content(result)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func content(_ result: QuickSearchModel.Result) -> some View {
        let workspace = Workspace.shared
        switch result.kind {
        case .file(let item):
            ThumbnailImage(url: item.url, contentMode: .fit, cornerRadius: 8, videoBadge: .duration)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)
            details([
                ("Folder", QuickSearchModel.folderName(of: item.url)),
                ("Kind", "\(item.format) \(kindName(item.kind))"),
                ("Size", ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)),
                ("Modified", item.modified.formatted(date: .abbreviated, time: .shortened)),
                ("Starred", workspace.isStarred(item.url) ? "Yes" : "No"),
            ])
            let tags = workspace.tags(for: item.url)
            if !tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(tags, id: \.name) { tag in
                        HStack(spacing: 4) {
                            Circle().fill(tag.displayColor).frame(width: 7, height: 7)
                            Text(tag.name).font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tag.displayColor.opacity(0.22), in: Capsule())
                    }
                }
            }
        case .folder(let url):
            let files = workspace.files[url] ?? []
            mosaic(files.map(\.url))
            Text(result.title).font(.system(size: 13, weight: .semibold))
            details([
                ("Path", result.subtitle),
                ("Images", "\(files.filter { $0.kind == .image }.count)"),
                ("Videos", "\(files.filter { $0.kind == .video }.count)"),
                ("Documents", "\(files.filter { $0.kind == .document }.count)"),
            ])
            Label("Live: new files show at once", systemImage: "dot.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .smart(let list):
            let urls = workspace.urls(for: list)
            mosaic(urls)
            Text(result.title).font(.system(size: 13, weight: .semibold))
            Text(urls.count == 1 ? "1 file from the workspace" : "\(urls.count) files from the workspace")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .board(let id):
            let urls = workspace.board(id)?.items.compactMap(\.url) ?? []
            mosaic(urls)
            Text(result.title).font(.system(size: 13, weight: .semibold))
            Text("\(result.accessory). A board keeps references to the files, not copies.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .command(let command):
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(height: 110)
                .overlay(Image(systemName: command.symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.secondary))
            Text(command.title).font(.system(size: 13, weight: .semibold))
            Text(command.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let shortcut = command.shortcut {
                HStack(spacing: 6) {
                    Text("Shortcut").font(.system(size: 12)).foregroundStyle(.tertiary)
                    KeyCap(shortcut)
                }
            }
        }
    }

    private func kindName(_ kind: ItemKind) -> String {
        switch kind {
        case .image: "image"
        case .video: "video"
        case .document: "document"
        }
    }

    @ViewBuilder
    private func mosaic(_ urls: [URL]) -> some View {
        let shown = Array(urls.prefix(4))
        if shown.isEmpty {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(height: 140)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)], spacing: 3) {
                ForEach(shown, id: \.self) { url in
                    ThumbnailImage(url: url, contentMode: .fill)
                        .frame(height: shown.count > 2 ? 68 : 140)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func details(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label).foregroundStyle(.tertiary)
                    Text(value).lineLimit(2).truncationMode(.middle)
                }
            }
        }
        .font(.system(size: 12))
    }
}
