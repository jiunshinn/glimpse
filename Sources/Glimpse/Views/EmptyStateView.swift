import SwiftUI

struct EmptyStateView: View {
    let model: ViewerModel
    let isDropTargeted: Bool

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
                Image(systemName: isFolderWithoutImages ? "photo.badge.exclamationmark" : "photo.stack")
                    .font(.system(size: 54, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(colors: [.white, .white.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    )
                    .symbolEffect(.bounce, value: isDropTargeted)
            }
            .scaleEffect(isDropTargeted ? 1.06 : 1)

            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            Button {
                NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil)
            } label: {
                Label("Open…", systemImage: "folder")
                    .padding(.horizontal, 8)
            }
            .prominentGlassButtonStyle()
            .controlSize(.large)

            HStack(spacing: 18) {
                KeyHint(keys: ["←", "→"], label: "Browse")
                KeyHint(keys: ["G"], label: "Grid")
                KeyHint(keys: ["F"], label: "Full screen")
                KeyHint(keys: ["?"], label: "Shortcuts")
            }
            .padding(.top, 6)
        }
        .padding(40)
    }

    private var isFolderWithoutImages: Bool {
        model.source != nil
    }

    private var title: String {
        isFolderWithoutImages ? "No images or videos in “\(model.collectionName)”" : "Drop images or a folder here"
    }

    private var subtitle: String {
        isFolderWithoutImages
            ? "Glimpse shows JPEG, PNG, HEIC, GIF, WebP, TIFF, RAW, MOV, MP4 and more."
            : "Open one image and browse the whole folder with the arrow keys."
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
