import SwiftUI

/// The content of a tab: the viewer or a board, and Quick Search above them.
struct TabContentView: View {
    let model: ViewerModel
    let tab: TabState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let id = tab.boardID {
                BoardView(boardID: id, tab: tab, topInset: model.topInset)
            } else {
                RootView(model: model)
            }

            if tab.quickSearch.isVisible {
                QuickSearchView(search: tab.quickSearch, topInset: model.topInset)
                    .transition(.motion(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)), reduceMotion: reduceMotion))
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.18), value: tab.quickSearch.isVisible)
    }
}
