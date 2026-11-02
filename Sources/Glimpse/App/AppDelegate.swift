import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controllers: [ViewerWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if controllers.isEmpty {
            // Paths passed on the command line (useful during development).
            let paths = CommandLine.arguments.dropFirst().filter { FileManager.default.fileExists(atPath: $0) }
            let urls = paths.map { URL(fileURLWithPath: $0) }
            if urls.isEmpty {
                showEmptyWindow()
            } else {
                open(urls)
            }
        }
        NSApp.activate()
        #if DEBUG
        applyDebugCommands()
        #endif
    }

    #if DEBUG
    /// Development aid: GLIMPSE_DEBUG="next,info" runs viewer commands after launch.
    /// It lets scripts put the window in a known state for screenshots. "wait" delays the next commands by 1 s.
    private func applyDebugCommands() {
        guard let commands = ProcessInfo.processInfo.environment["GLIMPSE_DEBUG"] else { return }
        var delay = 1.0
        for command in commands.split(separator: ",") {
            if command == "wait" {
                delay += 1
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let model = self?.controllers.first?.model else { return }
                    switch command {
                    case "next": model.next()
                    case "info": model.showInfo = true
                    case "grid": model.setGridMode(true)
                    case "shortcuts": model.showShortcuts = true
                    case "zoom": model.toggleZoom()
                    case "rotate": model.rotate(by: 1)
                    case "play": model.togglePlayback()
                    case "forward": model.seekVideo(by: 10)
                    case "faster": model.changeVideoSpeed(by: 1)
                    case "volume": model.changeVolume(by: -0.1)
                    case "loop": model.toggleLoop()
                    default: break
                    }
                }
            }
        }
    }
    #endif

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Closing the videos records where long videos stopped.
        controllers.forEach { $0.model.stopVideo() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEmptyWindow() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Opening

    func open(_ urls: [URL]) {
        let requests = OpenRequest.make(from: urls)
        guard !requests.isEmpty else {
            NSSound.beep()
            return
        }
        requests.forEach(route)
    }

    private func route(_ request: OpenRequest) {
        if case .folder(let folder, _) = request,
           let existing = controllers.first(where: { $0.model.source == .folder(folder) }) {
            existing.model.open(request)
            existing.showWindow(nil)
            return
        }
        let controller = controllers.first(where: { $0.model.isBlank }) ?? makeController()
        controller.model.open(request)
        controller.showWindow(nil)
    }

    private func showEmptyWindow() {
        let controller = controllers.first(where: { $0.model.isBlank }) ?? makeController()
        controller.showWindow(nil)
    }

    private func makeController() -> ViewerWindowController {
        let controller = ViewerWindowController(cascadingFrom: controllers.last?.window)
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        return controller
    }

    // MARK: - Actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .folder] + VideoDecoder.playableTypes
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose an image, a video or a folder."
        panel.prompt = "Open"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { self?.open(urls) }
        }
    }

    @objc func makeDefaultViewer(_ sender: Any?) {
        guard Bundle.main.bundleIdentifier != nil else {
            let alert = NSAlert()
            alert.messageText = "Run Glimpse from its app bundle"
            alert.informativeText = "Build the app with “make app” and open build/Glimpse.app, then try again."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Make Glimpse your default image viewer?"
        alert.informativeText = "JPEG, PNG, HEIC, GIF, WebP, TIFF, BMP and AVIF files will open in Glimpse when you double-click them in Finder."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let identifiers = ["public.jpeg", "public.png", "public.heic", "public.heif", "com.compuserve.gif",
                           "org.webmproject.webp", "public.tiff", "com.microsoft.bmp", "public.avif"]
        let types = identifiers.compactMap { UTType($0) }
        let appURL = Bundle.main.bundleURL
        Task {
            var failures: [String] = []
            for type in types {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
                } catch {
                    failures.append(type.preferredFilenameExtension ?? type.identifier)
                }
            }
            let done = NSAlert()
            if failures.isEmpty {
                done.messageText = "Glimpse is now your default image viewer."
            } else {
                done.messageText = "Some file types were not changed."
                done.informativeText = "Not changed: " + failures.joined(separator: ", ")
            }
            done.runModal()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        true
    }
}
