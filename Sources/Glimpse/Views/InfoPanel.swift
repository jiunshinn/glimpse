import SwiftUI

struct InfoPanel: View {
    let model: ViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                if let info = model.info {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(info.sections) { section in
                            SectionView(section: section)
                        }
                        if let coordinate = info.coordinate {
                            Button {
                                let query = "ll=\(coordinate.latitude),\(coordinate.longitude)&q=\(coordinate.latitude),\(coordinate.longitude)"
                                if let url = URL(string: "https://maps.apple.com/?\(query)") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label("Open in Maps", systemImage: "map")
                                    .frame(maxWidth: .infinity)
                            }
                            .glassButtonStyle()
                            .controlSize(.large)
                        }
                    }
                    .padding(18)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .scrollIndicators(.never)
        }
        .frame(width: Layout.infoPanelWidth)
        .frame(maxHeight: .infinity)
        .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onHover { model.pointerOverChrome = $0 }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.current?.name ?? "")
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(model.windowSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                model.showInfo = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Close Info (I)")
        }
        .padding(18)
    }
}

private struct SectionView: View {
    let section: ImageInfo.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(section.title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            ForEach(section.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 86, alignment: .leading)
                    Text(row.value)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
            }
        }
    }
}
