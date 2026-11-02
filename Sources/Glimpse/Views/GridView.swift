import SwiftUI

struct GridView: View {
    let model: ViewerModel

    private let spacing: CGFloat = 14
    private let padding: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width - padding * 2
            let columns = max(1, Int((available + spacing) / (CGFloat(model.gridTileSize) + spacing)))
            let tile = (available - CGFloat(columns - 1) * spacing) / CGFloat(columns)

            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: spacing), count: columns),
                              spacing: spacing + 4) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { offset, item in
                            GridCell(item: item, isSelected: offset == model.index, size: tile,
                                     marks: FileMarks(item.url))
                                .id(item.id)
                                .onTapGesture(count: 2) { model.openViewer(at: offset) }
                                .simultaneousGesture(TapGesture().onEnded { model.go(to: offset) })
                                .onDrag { OutgoingDrag.itemProvider(for: item.url) }
                        }
                    }
                    .padding(.horizontal, padding)
                    .padding(.top, model.topInset + 14)
                    .padding(.bottom, 28)
                    .padding(.trailing, model.showInfo ? Layout.infoPanelWidth + Layout.panelMargin : 0)
                }
                .scrollIndicators(.automatic)
                .onAppear {
                    model.gridColumns = columns
                    if let id = model.current?.id { scroller.scrollTo(id, anchor: .center) }
                }
                .onChange(of: columns) { _, newValue in model.gridColumns = newValue }
                .onChange(of: model.current?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.smooth(duration: 0.2)) { scroller.scrollTo(id) }
                }
            }
        }
    }
}

/// The star, the tags and the new-file mark of a file.
struct FileMarks: Equatable {
    var isStarred = false
    var tags: [FinderTag] = []
    var isNew = false

    @MainActor
    init(_ url: URL) {
        let workspace = Workspace.shared
        isStarred = workspace.isStarred(url)
        tags = workspace.tags(for: url)
        isNew = workspace.newFiles.contains(url)
    }
}

private struct GridCell: View {
    let item: ImageItem
    let isSelected: Bool
    let size: CGFloat
    let marks: FileMarks

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 8) {
            ThumbnailImage(url: item.url, contentMode: .fit, cornerRadius: 8, videoBadge: .duration)
                .padding(8)
                .frame(width: size, height: size)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(isSelected ? 0.14 : isHovered ? 0.07 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                }
                .overlay(alignment: .topLeading) { leadingMarks }
                .overlay(alignment: .topTrailing) { tagDots }
            Text(item.name)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background {
                    Capsule().fill(isSelected ? Color.accentColor : .clear)
                }
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(maxWidth: size)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(item.name)
    }

    @ViewBuilder
    private var leadingMarks: some View {
        HStack(spacing: 4) {
            if marks.isStarred {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.yellow)
            }
            if marks.isNew {
                Text("New")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.green, in: Capsule())
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
        .padding(12)
    }

    private var tagDots: some View {
        HStack(spacing: 3) {
            ForEach(marks.tags, id: \.name) { tag in
                Circle()
                    .fill(tag.displayColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
            }
        }
        .padding(12)
    }
}
