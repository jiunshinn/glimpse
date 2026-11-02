import SwiftUI

struct FilmstripView: View {
    let model: ViewerModel

    private let cellSize: CGFloat = 46
    private let spacing: CGFloat = 6
    private let padding: CGFloat = 9

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: spacing) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { offset, item in
                        FilmstripCell(url: item.url, isSelected: offset == model.index, size: cellSize,
                                      isNew: Workspace.shared.newFiles.contains(item.url))
                            .id(item.id)
                            .onTapGesture { model.go(to: offset) }
                            .onDrag { OutgoingDrag.itemProvider(for: item.url) }
                            .help(item.name)
                    }
                }
                .padding(.horizontal, padding)
                .frame(height: Layout.filmstripHeight)
            }
            .scrollIndicators(.never)
            .onChange(of: model.current?.id, initial: true) { _, id in
                guard let id else { return }
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: Layout.filmstripHeight)
        .frame(maxWidth: maxWidth)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onHover { model.pointerOverChrome = $0 }
    }

    /// The strip is only as wide as its thumbnails, up to a limit.
    private var maxWidth: CGFloat {
        let count = CGFloat(model.items.count)
        return min(count * cellSize + max(count - 1, 0) * spacing + padding * 2, 960)
    }
}

private struct FilmstripCell: View {
    let url: URL
    let isSelected: Bool
    let size: CGFloat
    let isNew: Bool

    @State private var isHovered = false

    var body: some View {
        ThumbnailImage(url: url, contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(isSelected ? 0.95 : 0), lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if isNew {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                        .padding(4)
                }
            }
            .scaleEffect(isSelected ? 1 : 0.86)
            .opacity(isSelected || isHovered ? 1 : 0.6)
            .shadow(color: .black.opacity(isSelected ? 0.4 : 0), radius: 6, y: 2)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.snappy(duration: 0.2), value: isSelected)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
