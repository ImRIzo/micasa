import AppKit
import UniformTypeIdentifiers

/// Opens viewers, routes keyboard input and menu commands to the active one.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [ViewerController] = []
    private var keyMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?

    private init() {}

    func start() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                WindowManager.shared.handleKeyDown(event)
            }
            return handled ? nil : event
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                WindowManager.shared.controllers.forEach { $0.refreshAppearance() }
            }
        }
    }

    var hasViewers: Bool { !controllers.isEmpty }

    /// The viewer the menu commands act on.
    var activeViewer: ViewerModel? {
        if let key = controllers.first(where: { $0.window.isKeyWindow }) { return key.model }
        if let main = controllers.first(where: { $0.window.isMainWindow }) { return main.model }
        return controllers.last?.model
    }

    // MARK: Opening

    func open(_ urls: [URL]) {
        let files = urls.compactMap(firstImage)
        guard !files.isEmpty else {
            NSSound.beep()
            return
        }

        // A single photo opened while a fullscreen viewer is up replaces what it shows.
        if files.count == 1, AppSettings.reuseFullscreenViewer,
           let viewer = controllers.last(where: { $0.model.mode == .fullscreen && !$0.model.isEditing }) {
            viewer.model.load(files[0])
            viewer.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let mode: ViewerMode = files.count == 1 && AppSettings.startInFullscreen ? .fullscreen : .floating
        for (index, file) in files.prefix(32).enumerated() {
            let controller = ViewerController(mode: mode)
            controllers.append(controller)
            controller.show(file, cascadeIndex: index)
        }
    }

    /// A file stays as is; a folder opens its first photo (the rest are a ←/→ away).
    private func firstImage(_ url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return ImageFormats.images(in: url).first
        }
        return url
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageFormats.readableTypes + [.folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose photos or a folder to open in Micasa"
        if let url = activeViewer?.url {
            panel.directoryURL = url.deletingLastPathComponent()
        }
        NSApp.activate()
        if panel.runModal() == .OK {
            open(panel.urls)
        }
    }

    func controllerDidClose(_ controller: ViewerController) {
        controllers.removeAll { $0 === controller }
    }

    // MARK: Keyboard

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = event.window as? ViewerWindow,
              let controller = controllers.first(where: { $0.window === window }) else {
            return false
        }
        // Let text fields (e.g. the custom crop ratio) keep their keys.
        if window.firstResponder is NSText || window.firstResponder is NSTextField {
            return false
        }
        return controller.model.handleKey(event)
    }
}
