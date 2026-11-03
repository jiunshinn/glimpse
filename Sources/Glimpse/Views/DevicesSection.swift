import SwiftUI

/// The paired phones in the sidebar: their albums and their folders.
struct DevicesSection: View {
    let tab: TabState

    private var library: DeviceLibrary { .shared }

    var body: some View {
        if !library.phones.isEmpty {
            Section("Devices") {
                ForEach(library.phones) { phone in
                    PhoneRows(tab: tab, phone: phone)
                }
            }
        }
    }
}

private struct PhoneRows: View {
    let tab: TabState
    let phone: Phone

    @State private var expanded = true
    @State private var photosExpanded = true
    private var library: DeviceLibrary { .shared }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if library.isOnline(phone) {
                DisclosureGroup(isExpanded: $photosExpanded) {
                    ForEach(library.albums[phone.id] ?? []) { album in
                        let item = SidebarItem.device(.album(device: phone.id, id: album.id))
                        Label(album.name, systemImage: "photo.on.rectangle")
                            .badge(album.count)
                            .tag(item)
                            .contextMenu { openInNewTab(item) }
                    }
                } label: {
                    Label("Photos", systemImage: "photo.stack")
                }
                .onChange(of: photosExpanded) { _, open in
                    if open { library.refresh(phone.id) }
                }
                FolderRow(tab: tab, phone: phone, folder: PhoneFolder(path: "", name: "Files", count: 0), isRoot: true)
                if let problem = library.problems["\(phone.id)/files"] {
                    hint(problem)
                }
            } else {
                hint("Not connected. On the phone, open Glimpse and turn on “Share with your Mac”, or connect the phone with a USB cable.")
            }
        } label: {
            Label {
                Text(phone.name)
            } icon: {
                Image(systemName: "smartphone")
                    .foregroundStyle(library.isOnline(phone) ? Color.accentColor : .secondary)
            }
            .badge(phone.usbPort != nil ? Text(Image(systemName: "cable.connector")) : nil)
            .help(phone.usbPort != nil ? "Connected with a USB cable" : library.isOnline(phone) ? "Connected over Wi-Fi" : "Not connected")
            .accessibilityValue(phone.usbPort != nil ? "Connected with a USB cable"
                                : library.isOnline(phone) ? "Connected over Wi-Fi" : "Not connected")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .selectionDisabled()
    }

    private func openInNewTab(_ item: SidebarItem) -> some View {
        Button("Open in New Tab") { tab.controller?.openSidebarItem(item, inNewTab: true) }
    }
}

/// A phone folder. Its subfolders load when the row opens.
private struct FolderRow: View {
    let tab: TabState
    let phone: Phone
    let folder: PhoneFolder
    var isRoot = false

    @State private var expanded = false
    private var library: DeviceLibrary { .shared }

    var body: some View {
        let item = SidebarItem.device(.folder(device: phone.id, path: folder.path))
        let label = Label(folder.name, systemImage: isRoot ? "folder.badge.gearshape" : "folder")
            .tag(item)
            .contextMenu { Button("Open in New Tab") { tab.controller?.openSidebarItem(item, inNewTab: true) } }
        let children = library.subfolders(phone.id, path: folder.path)
        if !isRoot && folder.count == 0 {
            label
        } else if let children, children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children ?? []) { child in
                    FolderRow(tab: tab, phone: phone, folder: child)
                }
            } label: {
                label
            }
            .onChange(of: expanded) { _, open in
                if open { library.loadFolders(phone.id, path: folder.path) }
            }
        }
    }
}
