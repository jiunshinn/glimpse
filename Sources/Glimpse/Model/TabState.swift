import Foundation
import Observation

/// A row in the sidebar.
enum SidebarItem: Hashable {
    case smart(SmartList)
    /// A folder in Favorites. It opens the same folder as the row in Folders.
    case pinned(URL)
    case folder(URL)
    case board(UUID)
}

/// What a tab shows.
enum TabTarget: Equatable {
    case request(OpenRequest)
    case board(UUID)
}

/// Where a sidebar item or a Quick Search result opens.
enum TabPlacement {
    /// In the tab that shows it already, or else in the current tab.
    case reuseOrCurrent
    case current
    case newTab
}

/// The workspace state of one tab: the board that it shows, the sidebar selection and Quick Search.
@MainActor
@Observable
final class TabState {
    /// The board that the tab shows. Nil when the tab shows the viewer.
    var boardID: UUID?
    /// The selected board item. ⌫ removes it from the board.
    var boardSelection: UUID?
    /// The note that gets the keyboard focus next.
    var focusedNote: UUID?
    /// The width of the visible part of the board. Arrange uses it.
    @ObservationIgnored var boardViewportWidth: CGFloat = 800
    /// The sidebar row that shows as selected.
    var sidebarSelection: SidebarItem?
    let quickSearch = QuickSearchModel()

    @ObservationIgnored weak var controller: ViewerWindowController? {
        didSet { quickSearch.controller = controller }
    }
}
