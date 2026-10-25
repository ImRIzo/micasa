import AppKit
import SwiftUI

/// Entry point. Micasa uses the AppKit app lifecycle: viewer windows need borderless /
/// fullscreen behaviour SwiftUI scenes don't offer, and a SwiftUI `App` whose only scene is
/// `Settings` makes macOS show or restore the Settings window on its own. All the
/// interface inside the windows is still SwiftUI.
@main
enum MicasaMain {
    private static var appDelegate: AppDelegate?

    static func main() {
        MainActor.assumeIsolated {
            AppSettings.registerDefaults()
            // Don't reopen last session's windows at launch.
            UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
            let app = NSApplication.shared
            let delegate = AppDelegate()
            appDelegate = delegate
            app.delegate = delegate
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedFilesAtLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Needed when run straight from Xcode / `swift run` (outside an .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build()
    }

    /// Never bring back windows (such as Settings) from the previous session.
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            WindowManager.shared.start()
        }
        // Give Finder's "open file" event a moment to arrive before offering the open panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.openedFilesAtLaunch else { return }
            MainActor.assumeIsolated {
                if !WindowManager.shared.hasViewers {
                    WindowManager.shared.showOpenPanel()
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFilesAtLaunch = true
        MainActor.assumeIsolated {
            WindowManager.shared.open(urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !WindowManager.shared.hasViewers {
                WindowManager.shared.showOpenPanel()
            }
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Remove extracted Motion Photo clips.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MicasaMotion")
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The menu bar. Plain-key shortcuts (←, →, F, 1, E, Esc…) are handled per window.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, title: "Micasa")
        app.addItem(withTitle: "About Micasa",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(ActionItem("Settings…", key: ",") { SettingsWindowController.shared.show() })
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Micasa", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others",
                                     action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Micasa", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, title: "File")
        file.addItem(ActionItem("Open…", key: "o") { WindowManager.shared.showOpenPanel() })
        file.addItem(ActionItem("Close", key: "w") { NSApp.keyWindow?.performClose(nil) })
        file.addItem(.separator())
        file.addItem(ActionItem("Save Edited Copy", key: "s") { onViewer { $0.saveEditedCopy(saveAs: false) } })
        file.addItem(ActionItem("Save As…", key: "s", modifiers: [.command, .shift]) {
            onViewer { $0.saveEditedCopy(saveAs: true) }
        })
        file.addItem(ActionItem("Save Motion Video…") { onViewer { $0.saveMotionVideo() } })
        file.addItem(.separator())
        file.addItem(ActionItem("Show in Finder", key: "r", modifiers: [.command, .shift]) {
            onViewer { $0.revealInFinder() }
        })
        file.addItem(ActionItem("Move to Trash", key: "\u{8}") { onViewer { $0.moveToTrash() } })

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(ActionItem("Undo", key: "z") {
            if NSApp.keyWindow is ViewerWindow {
                onViewer { $0.editor.undo() }
            } else {
                _ = NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            }
        })
        edit.addItem(ActionItem("Redo", key: "z", modifiers: [.command, .shift]) {
            if NSApp.keyWindow is ViewerWindow {
                onViewer { $0.editor.redo() }
            } else {
                _ = NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            }
        })
        edit.addItem(.separator())
        // Standard text editing for the text fields (crop ratio, settings).
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu(in: main, title: "View")
        view.addItem(ActionItem("Fullscreen / Floating", key: "f", modifiers: [.command, .control]) {
            onViewer { $0.toggleMode() }
        })
        view.addItem(.separator())
        view.addItem(ActionItem("Zoom In", key: "=") { onViewer { $0.zoom(by: 1.25) } })
        view.addItem(ActionItem("Zoom Out", key: "-") { onViewer { $0.zoom(by: 1 / 1.25) } })
        view.addItem(ActionItem("Zoom to Fit", key: "0") { onViewer { $0.fit() } })
        view.addItem(ActionItem("Actual Pixels", key: "1") { onViewer { $0.actualPixels() } })
        view.addItem(.separator())
        view.addItem(ActionItem("Show Info", key: "i") { onViewer { $0.showInfo.toggle() } })
        view.addItem(ActionItem("Play / Pause Motion", key: "p") { onViewer { $0.togglePlayback() } })

        let image = submenu(in: main, title: "Image")
        image.addItem(ActionItem("Previous Photo", key: "[") { onViewer { $0.browse(-1) } })
        image.addItem(ActionItem("Next Photo", key: "]") { onViewer { $0.browse(1) } })
        image.addItem(.separator())
        image.addItem(ActionItem("Edit", key: "e") { onViewer { $0.toggleEditor() } })
        image.addItem(ActionItem("Crop", key: "k") { onEditor { $0.beginCrop() } })
        image.addItem(ActionItem("Rotate Right", key: "r") { onEditor { $0.rotate(clockwise: true) } })
        image.addItem(ActionItem("Rotate Left", key: "l") { onEditor { $0.rotate(clockwise: false) } })
        image.addItem(.separator())
        image.addItem(ActionItem("Reset Adjustments", key: "r", modifiers: [.command, .option]) {
            onViewer { $0.editor.resetAdjustments() }
        })

        let window = submenu(in: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }
}

/// The Settings window (⌘,), created on demand and never restored at launch.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Micasa Settings"
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.tabbingMode = .disallowed
            w.contentView = NSHostingView(rootView: SettingsView().frame(width: 460))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// Menu actions always run on the main thread. These helpers state that to the compiler
// in a way that works whether or not the SDK marks Button actions as @MainActor.

private func onMain(_ action: @MainActor () -> Void) {
    MainActor.assumeIsolated { action() }
}

private func onViewer(_ action: @MainActor (ViewerModel) -> Void) {
    MainActor.assumeIsolated {
        if let viewer = WindowManager.shared.activeViewer { action(viewer) }
    }
}

/// Runs `action` on the active viewer's editor, opening the editor first if needed.
private func onEditor(_ action: @MainActor (EditorSession) -> Void) {
    MainActor.assumeIsolated {
        guard let viewer = WindowManager.shared.activeViewer, viewer.info != nil else { return }
        if !viewer.isEditing { viewer.openEditor() }
        action(viewer.editor)
    }
}
