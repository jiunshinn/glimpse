import AVKit
import SwiftUI

/// Plays the current video with the system player controls, fitted in the uncovered area.
struct VideoStage: View {
    let model: ViewerModel

    var body: some View {
        let insets = model.videoInsets
        PlayerViewRepresentable(player: model.video.player) { event in
            // A two-finger swipe over the video changes the item, as it does over an image.
            model.canvas?.scrollWheel(with: event)
        }
        .aspectRatio(model.videoSize ?? CGSize(width: 16, height: 9), contentMode: .fit)
        .opacity(model.videoSize == nil ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right))
    }
}

private struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    let onScroll: (NSEvent) -> Void

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        // F toggles full screen for the whole window. The player's own full screen would leave the folder behind.
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = true
        view.player = player
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.player = nil
    }
}

final class PlayerView: AVPlayerView {
    var onScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let onScroll {
            onScroll(event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
