import AppKit
import SwiftUI

extension FinderTag {
    var displayColor: Color {
        switch color {
        case 1: .gray
        case 2: .green
        case 3: .purple
        case 4: .blue
        case 5: .yellow
        case 6: .red
        case 7: .orange
        default: Color.white.opacity(0.45)
        }
    }
}

/// The folders, favorites, tags and boards of the workspace.
struct SidebarView: View {
    let tab: TabState

    @State private var renamingBoard: UUID?
    @State private var boardName = ""
    @State private var deletingBoard: UUID?

    private var workspace: Workspace { .shared }

    var body: some View {
        List(selection: selection) {
            Section("Favorites") {
                Label {
                    Text("Starred")
                } icon: {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                .badge(workspace.stars.count)
                .tag(SidebarItem.smart(.starred))
                .contextMenu { openInNewTab(.smart(.starred)) }

                ForEach(workspace.folders.filter(\.isPinned)) { folder in
                    folderLabel(folder)
                        .tag(SidebarItem.pinned(folder.url))
                        .contextMenu { folderMenu(folder, item: .pinned(folder.url)) }
                }
            }

            Section("Folders") {
                ForEach(workspace.folders) { folder in
                    folderLabel(folder)
                        .badge(workspace.count(in: folder.url))
                        .tag(SidebarItem.folder(folder.url))
                        .contextMenu { folderMenu(folder, item: .folder(folder.url)) }
                }
                .onMove { workspace.moveFolders(from: $0, to: $1) }

                Button {
                    NSApp.sendAction(#selector(AppDelegate.addFolderToWorkspace(_:)), to: nil, from: nil)
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add a folder to the workspace (⇧⌘O). You can also drop a folder here.")
            }

            Section("Tags") {
                ForEach(workspace.knownTags, id: \.name) { tag in
                    Label {
                        Text(tag.name)
                    } icon: {
                        Circle().fill(tag.displayColor).frame(width: 10, height: 10)
                    }
                    .badge(workspace.tagCounts[tag.name] ?? 0)
                    .tag(SidebarItem.smart(.tag(tag.name)))
                    .contextMenu { openInNewTab(.smart(.tag(tag.name))) }
                    .help(shortcutHelp(for: tag))
                }
            }

            Section("Boards") {
                ForEach(workspace.boards) { board in
                    Label(board.name, systemImage: "rectangle.3.group")
                        .badge(board.items.count)
                        .tag(SidebarItem.board(board.id))
                        .contextMenu {
                            openInNewTab(.board(board.id))
                            Divider()
                            Button("Rename…") {
                                boardName = board.name
                                renamingBoard = board.id
                            }
                            Button("Delete Board…", role: .destructive) { deletingBoard = board.id }
                        }
                }

                Button {
                    tab.controller?.newBoard(nil)
                } label: {
                    Label("New Board", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .dropDestination(for: URL.self) { urls, _ in
            !workspace.addFolders(urls).isEmpty
        }
        .alert("Rename Board", isPresented: isRenaming) {
            TextField("Name", text: $boardName)
            Button("Rename") {
                if let id = renamingBoard { workspace.renameBoard(id, to: boardName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this board?", isPresented: isDeleting) {
            Button("Delete Board", role: .destructive) {
                if let id = deletingBoard { tab.controller?.deleteBoard(id) }
            }
        } message: {
            Text("The files stay in their folders. Only the board and its notes go away.")
        }
    }

    // MARK: - Rows

    private func folderLabel(_ folder: WorkspaceFolder) -> some View {
        let unreadable = workspace.unreadableFolders.contains(folder.url)
        let newCount = workspace.newCount(in: folder.url)
        return Label {
            HStack(spacing: 6) {
                Text(folder.name)
                if newCount > 0 {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .help(newCount == 1 ? "1 new file" : "\(newCount) new files")
                }
            }
        } icon: {
            Image(systemName: unreadable ? "exclamationmark.triangle" : "folder")
                .foregroundStyle(unreadable ? Color.yellow : Color.accentColor)
        }
        .help(unreadable ? "Glimpse can’t read \(folder.url.path)" : folder.url.path)
    }

    @ViewBuilder
    private func folderMenu(_ folder: WorkspaceFolder, item: SidebarItem) -> some View {
        openInNewTab(item)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
        Divider()
        Button(folder.isPinned ? "Remove from Favorites" : "Add to Favorites") {
            workspace.setPinned(!folder.isPinned, for: folder.url)
        }
        Button("Remove from Workspace") { workspace.removeFolder(folder.url) }
    }

    private func openInNewTab(_ item: SidebarItem) -> some View {
        Button("Open in New Tab") { tab.controller?.openSidebarItem(item, inNewTab: true) }
    }

    private func shortcutHelp(for tag: FinderTag) -> String {
        guard let index = FinderTag.quickTags.firstIndex(of: tag) else { return tag.name }
        return "Press \(index + 1) to add or remove \(tag.name)"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("Reopen at Launch")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            Toggle("Reopen at Launch", isOn: reopenAtLaunch)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help("Open the same tabs, files, views and filters at the next launch")
    }

    // MARK: - Bindings

    /// A click opens the row in this tab. ⌘-click opens it in a new tab.
    private var selection: Binding<SidebarItem?> {
        Binding {
            tab.sidebarSelection
        } set: { item in
            guard let item else { return }
            let inNewTab = NSEvent.modifierFlags.contains(.command)
            tab.controller?.openSidebarItem(item, inNewTab: inNewTab)
        }
    }

    private var reopenAtLaunch: Binding<Bool> {
        Binding { workspace.reopenAtLaunch } set: { workspace.reopenAtLaunch = $0 }
    }

    private var isRenaming: Binding<Bool> {
        Binding { renamingBoard != nil } set: { if !$0 { renamingBoard = nil } }
    }

    private var isDeleting: Binding<Bool> {
        Binding { deletingBoard != nil } set: { if !$0 { deletingBoard = nil } }
    }
}
