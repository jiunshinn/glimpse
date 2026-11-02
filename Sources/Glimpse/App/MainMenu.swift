import AppKit

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(container(appMenu()))
        main.addItem(container(fileMenu()))
        main.addItem(container(editMenu()))
        main.addItem(container(viewMenu()))
        main.addItem(container(workspaceMenu()))
        main.addItem(container(playbackMenu()))
        main.addItem(container(goMenu()))
        let window = windowMenu()
        main.addItem(container(window))
        let help = helpMenu()
        main.addItem(container(help))
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        return main
    }

    /// The sort menu is built twice: once for the View menu and once for the toolbar.
    static func sortMenu() -> NSMenu {
        let menu = NSMenu(title: "Sort By")
        for key in SortKey.allCases {
            menu.addItem(item(key.title, #selector(ViewerWindowController.setSortKey(_:)), tag: key.rawValue))
        }
        menu.addItem(.separator())
        menu.addItem(item("Ascending", #selector(ViewerWindowController.setSortOrder(_:)), tag: 1))
        menu.addItem(item("Descending", #selector(ViewerWindowController.setSortOrder(_:)), tag: 0))
        return menu
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Glimpse")
        menu.addItem(item("About Glimpse", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Make Default Image Viewer…", #selector(AppDelegate.makeDefaultViewer(_:))))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide Glimpse", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Glimpse", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Tab", #selector(ViewerWindowController.newWindowForTab(_:)), "t"))
        menu.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o"))
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(ViewerWindowController.closeTab(_:)), "w"))
        menu.addItem(item("Close Window", #selector(ViewerWindowController.closeWindowAndTabs(_:)), "w", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Show in Finder", #selector(ViewerWindowController.revealInFinder(_:)), "r", [.command, .shift]))
        menu.addItem(item("Move to Trash", #selector(ViewerWindowController.moveToTrash(_:)), "\u{8}"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Copy", #selector(ViewerWindowController.copy(_:)), "c"))
        menu.addItem(item("Copy File Path", #selector(ViewerWindowController.copyPath(_:)), "c", [.command, .option]))
        menu.addItem(item("Copy Frame", #selector(ViewerWindowController.copyFrame(_:)), "c", [.command, .shift]))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Show Sidebar", #selector(ViewerWindowController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Grid", #selector(ViewerWindowController.toggleGrid(_:)), "g", []))
        menu.addItem(item("Thumbnails", #selector(ViewerWindowController.toggleThumbnails(_:)), "t", []))
        menu.addItem(item("Info", #selector(ViewerWindowController.toggleInfo(_:)), "i", []))
        menu.addItem(item("Ambient Background", #selector(ViewerWindowController.toggleAmbientBackground(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Zoom In", #selector(ViewerWindowController.zoomIn(_:)), "="))
        menu.addItem(item("Zoom Out", #selector(ViewerWindowController.zoomOut(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(ViewerWindowController.zoomToActualSize(_:)), "0"))
        menu.addItem(item("Zoom to Fit", #selector(ViewerWindowController.zoomToFit(_:)), "9"))
        menu.addItem(.separator())
        menu.addItem(item("Rotate Left", #selector(ViewerWindowController.rotateLeft(_:)), "l"))
        menu.addItem(item("Rotate Right", #selector(ViewerWindowController.rotateRight(_:)), "r"))
        menu.addItem(.separator())
        let sort = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sort.submenu = sortMenu()
        menu.addItem(sort)
        let types = NSMenuItem(title: "File Types", action: nil, keyEquivalent: "")
        types.submenu = fileTypesMenu()
        menu.addItem(types)
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    /// The kinds of files that the viewer shows. The toolbar menu also has the formats.
    private static func fileTypesMenu() -> NSMenu {
        let menu = NSMenu(title: "File Types")
        let action = #selector(ViewerWindowController.setFilterKind(_:))
        menu.addItem(item("All Types", action, tag: 0))
        menu.addItem(.separator())
        menu.addItem(item("Images Only", action, tag: 1))
        menu.addItem(item("Videos Only", action, tag: 2))
        menu.addItem(item("Documents Only", action, tag: 3))
        return menu
    }

    /// Single keys (S, P, ⇧P, B, 1 to 5) work while the viewer or the grid shows.
    private static func workspaceMenu() -> NSMenu {
        typealias Controller = ViewerWindowController
        let menu = NSMenu(title: "Workspace")
        menu.addItem(item("Quick Search…", #selector(Controller.showQuickSearch(_:)), "k"))
        menu.addItem(.separator())
        menu.addItem(item("Add Folder to Workspace…", #selector(AppDelegate.addFolderToWorkspace(_:)), "o", [.command, .shift]))
        menu.addItem(item("Add Current Folder to Workspace", #selector(Controller.addCurrentFolderToWorkspace(_:))))
        menu.addItem(item("Pin Folder to Favorites", #selector(Controller.toggleFolderPin(_:)), "p", [.shift]))
        menu.addItem(.separator())
        menu.addItem(item("Pin to Top", #selector(Controller.toggleFilePin(_:)), "p", []))
        menu.addItem(item("Star", #selector(Controller.toggleStar(_:)), "s", []))
        let tags = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        let tagMenu = NSMenu(title: "Tags")
        for (index, tag) in FinderTag.quickTags.enumerated() {
            tagMenu.addItem(item(tag.name, #selector(Controller.toggleTag(_:)), "\(index + 1)", [], tag: index))
        }
        tags.submenu = tagMenu
        menu.addItem(tags)
        menu.addItem(item("Add to Board", #selector(Controller.addCurrentFileToBoard(_:)), "b", []))
        menu.addItem(.separator())
        menu.addItem(item("New Board", #selector(Controller.newBoard(_:))))
        menu.addItem(item("Add Files to Board…", #selector(Controller.addFilesToBoard(_:))))
        menu.addItem(item("Add Note", #selector(Controller.addNote(_:))))
        menu.addItem(item("Arrange Board", #selector(Controller.arrangeBoard(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Reopen Tabs at Launch", #selector(AppDelegate.toggleReopenAtLaunch(_:))))
        return menu
    }

    /// Single keys without ⌘ work only while a video shows. With an image, the same keys do other things.
    private static func playbackMenu() -> NSMenu {
        typealias Controller = ViewerWindowController
        let menu = NSMenu(title: "Playback")
        menu.addItem(item("Play/Pause", #selector(Controller.togglePlayback(_:)), " ", []))
        menu.addItem(item("Loop", #selector(Controller.toggleLoop(_:)), "l", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Jump Back 5 Seconds", #selector(Controller.jumpBack(_:)), key(NSLeftArrowFunctionKey), [.shift], tag: 5))
        menu.addItem(item("Jump Forward 5 Seconds", #selector(Controller.jumpForward(_:)), key(NSRightArrowFunctionKey), [.shift], tag: 5))
        menu.addItem(item("Jump Back 10 Seconds", #selector(Controller.jumpBack(_:)), "j", [], tag: 10))
        menu.addItem(item("Jump Forward 10 Seconds", #selector(Controller.jumpForward(_:)), "l", [], tag: 10))
        menu.addItem(item("Previous Frame", #selector(Controller.previousFrame(_:)), ",", []))
        menu.addItem(item("Next Frame", #selector(Controller.nextFrame(_:)), ".", []))
        menu.addItem(.separator())
        menu.addItem(item("Slower", #selector(Controller.slower(_:)), "[", []))
        menu.addItem(item("Faster", #selector(Controller.faster(_:)), "]", []))
        menu.addItem(item("Normal Speed", #selector(Controller.normalSpeed(_:)), "\\", []))
        menu.addItem(.separator())
        menu.addItem(item("Volume Up", #selector(Controller.volumeUp(_:)), "=", []))
        menu.addItem(item("Volume Down", #selector(Controller.volumeDown(_:)), "-", []))
        menu.addItem(item("Mute", #selector(Controller.toggleMute(_:)), "m", []))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Next Image", #selector(ViewerWindowController.nextImage(_:)), key(NSRightArrowFunctionKey), []))
        menu.addItem(item("Previous Image", #selector(ViewerWindowController.previousImage(_:)), key(NSLeftArrowFunctionKey), []))
        menu.addItem(.separator())
        menu.addItem(item("First Image", #selector(ViewerWindowController.firstImage(_:)), key(NSUpArrowFunctionKey)))
        menu.addItem(item("Last Image", #selector(ViewerWindowController.lastImage(_:)), key(NSDownArrowFunctionKey)))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Keyboard Shortcuts", #selector(ViewerWindowController.showShortcuts(_:)), "/"))
        return menu
    }

    // MARK: - Helpers

    private static func container(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ keyEquivalent: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : modifiers
        item.tag = tag
        return item
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(UInt32(functionKey))!))
    }
}
