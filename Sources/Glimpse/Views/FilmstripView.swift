import SwiftUI

struct FilmstripView: View {
    let model: ViewerModel

    private let cellSize: CGFloat = 46
    private let spacing: CGFloat = 6
    private let padding: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: spacing) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { offset, item in
                        FilmstripCell(url: item.url, isSelected: offset == model.index, size: cellSize,
                                      isNew: Workspace.shared.newFiles.contains(item.url),
                                      isPinned: Workspace.shared.isFilePinned(item.url))
                            .id(item.id)
                            .onTapGesture { model.go(to: offset) }
                            .onDrag { OutgoingDrag.itemProvider(for: item.url) }
                            .contextMenu { FileContextMenu(model: model, url: item.url) }
                            .help(item.name)
                            .fileAccessibility(item, marks: FileMarks(item.url), isSelected: offset == model.index,
                                               model: model) { model.go(to: offset) }
                    }
                }
                .padding(.horizontal, padding)
                .frame(height: Layout.filmstripHeight)
            }
            .scrollIndicators(.never)
            .onChange(of: model.current?.id, initial: true) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: Layout.filmstripHeight)
        .frame(maxWidth: maxWidth)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thumbnails")
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
    let isPinned: Bool

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

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
            .overlay(alignment: .topLeading) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.orange)
                        .rotationEffect(.degrees(45))
                        .shadow(color: .black.opacity(0.7), radius: 1.5)
                        .padding(4)
                }
            }
            .scaleEffect(isSelected ? 1 : 0.86)
            // Increase Contrast keeps the other thumbnails easy to see.
            .opacity(isSelected || isHovered ? 1 : contrast == .increased ? 0.85 : 0.6)
            .shadow(color: .black.opacity(isSelected ? 0.4 : 0), radius: 6, y: 2)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isSelected)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
