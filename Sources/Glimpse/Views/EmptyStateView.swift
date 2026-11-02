import SwiftUI

struct EmptyStateView: View {
    let model: ViewerModel
    let isDropTargeted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color.accentColor.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 420)
                .opacity(isDropTargeted ? 1 : 0.55)
                .allowsHitTesting(false)

            if model.isScanning {
                ProgressView()
                    .controlSize(.large)
            } else {
                content
            }
        }
        .animation(.smooth(duration: 0.25), value: isDropTargeted)
    }

    private var content: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.white.opacity(0.2))
                    .frame(width: 150, height: 150)
                Image(systemName: symbol)
                    .font(.system(size: 54, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(colors: [.white, .white.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    )
                    .symbolEffect(.bounce, value: reduceMotion ? false : isDropTargeted)
            }
            .scaleEffect(isDropTargeted && !reduceMotion ? 1.06 : 1)
            .accessibilityHidden(true)

            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)

            if model.filterHidesAll {
                Button {
                    model.filter = TypeFilter()
                } label: {
                    Label("Show All Types", systemImage: "line.3.horizontal.decrease.circle")
                        .padding(.horizontal, 8)
                }
                .prominentGlassButtonStyle()
                .controlSize(.large)
                .reportsKeyboardFocus(to: model)
            } else if model.source == nil {
                Button {
                    NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil)
                } label: {
                    Label("Open…", systemImage: "folder")
                        .padding(.horizontal, 8)
                }
                .prominentGlassButtonStyle()
                .controlSize(.large)
                .reportsKeyboardFocus(to: model)
            }

            HStack(spacing: 18) {
                if model.source == nil {
                    KeyHint(keys: ["⌘K"], label: "Search the workspace")
                }
                KeyHint(keys: ["←", "→"], label: "Browse")
                KeyHint(keys: ["G"], label: "Grid")
                KeyHint(keys: ["?"], label: "Shortcuts")
            }
            .padding(.top, 6)
        }
        .padding(40)
    }

    private var symbol: String {
        if model.filterHidesAll { return "line.3.horizontal.decrease.circle" }
        switch model.source {
        case .smart(.starred): return "star"
        case .smart(.tag): return "tag"
        case nil: return "photo.stack"
        default: return "photo.badge.exclamationmark"
        }
    }

    private var title: String {
        if model.filterHidesAll {
            return "No \(model.filter.title.lowercased()) in “\(model.collectionName)”"
        }
        switch model.source {
        case .smart(.starred): return "No starred files"
        case .smart(.tag(let name)): return "No files with the tag “\(name)”"
        case nil: return "Drop images or a folder here"
        default: return "No images, videos or documents in “\(model.collectionName)”"
        }
    }

    private var subtitle: String {
        if model.filterHidesAll {
            let count = model.allItems.count
            return count == 1 ? "The filter hides the only file here." : "The filter hides all \(count) files here."
        }
        switch model.source {
        case .smart(.starred): return "Press S to star a file. Starred files from all folders show here."
        case .smart(.tag): return "Press 1 to 5 to tag a file. Glimpse looks for tags in the workspace folders."
        case nil: return "Open one image and browse the whole folder with the arrow keys."
        default: return "Glimpse shows JPEG, PNG, HEIC, GIF, WebP, TIFF, RAW, MOV, MP4, PDF, Word, Excel and more."
        }
    }
}

struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { KeyCap($0) }
            }
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(keys.map(ShortcutsOverlay.spokenKeys).joined(separator: ", "))")
    }
}

struct KeyCap: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            )
    }
}
