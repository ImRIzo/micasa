import AppKit
import SwiftUI

/// Transparent AppKit view under the overlay controls that turns mouse, trackpad and
/// drag-and-drop input into viewer actions. SwiftUI has no scroll-wheel or
/// window-drag events, so this part is AppKit.
@MainActor
struct EventCatcher: NSViewRepresentable {
    let model: ViewerModel

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.model = model
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.model = model
    }
}

@MainActor
final class CatcherView: NSView {
    weak var model: ViewerModel?
    private var lastDragPoint: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        model.noteActivity()
        if event.clickCount == 2 {
            model.toggleMode()
            return
        }
        if model.mode == .floating && !model.isEditing {
            // Floating windows are moved by dragging the photo.
            window?.performDrag(with: event)
            return
        }
        lastDragPoint = event.locationInWindow
        if model.canPan { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let last = lastDragPoint else { return }
        let point = event.locationInWindow
        // Window coordinates grow upwards; the view's grow downwards.
        model.pan(by: CGSize(width: point.x - last.x, height: last.y - point.y))
        lastDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        model?.noteActivity()
    }

    // MARK: Scroll, pinch, swipe

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        model.noteActivity()
        let point = convert(event.locationInWindow, from: nil)
        let zoomModifier = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)

        if event.hasPreciseScrollingDeltas && !zoomModifier {
            // Trackpad / Magic Mouse: two-finger scroll pans; pinch zooms (see magnify).
            if model.mode == .fullscreen || model.isEditing {
                model.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            }
            return
        }

        // Mouse wheel, or ⌘/⌥ + trackpad scroll: zoom around the pointer.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY
        guard delta != 0 else { return }
        let factor = pow(1.15, max(-4, min(4, delta)))
        model.zoom(by: factor, at: point)
    }

    override func magnify(with event: NSEvent) {
        guard let model else { return }
        model.noteActivity()
        let point = convert(event.locationInWindow, from: nil)
        model.zoom(by: max(0.5, 1 + event.magnification), at: point)
    }

    override func smartMagnify(with event: NSEvent) {
        guard let model else { return }
        if model.isFit || model.mode == .floating {
            model.actualPixels()
        } else {
            model.fit()
        }
    }

    override func swipe(with event: NSEvent) {
        guard let model, event.deltaX != 0 else { return }
        model.browse(event.deltaX > 0 ? -1 : 1)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionItem("Open…") { WindowManager.shared.showOpenPanel() })
        menu.addItem(.separator())
        menu.addItem(ActionItem(model.isEditing ? "Close Editor" : "Edit") { model.toggleEditor() })
        menu.addItem(ActionItem(model.mode == .fullscreen ? "Floating Window" : "Fullscreen") { model.toggleMode() })
        menu.addItem(ActionItem("Zoom to Fit") { model.fit() })
        menu.addItem(ActionItem("Actual Pixels") { model.actualPixels() })
        if model.motion != nil {
            menu.addItem(ActionItem(model.isMotionPlaying ? "Stop Motion" : "Play Motion") { model.togglePlayback() })
            menu.addItem(ActionItem("Save Motion Video…") { model.saveMotionVideo() })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Show in Finder") { model.revealInFinder() })
        menu.addItem(ActionItem("Copy") {
            guard let url = model.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        })
        menu.addItem(ActionItem("Move to Trash") { model.moveToTrash() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Close") { model.presentingWindow?.performClose(nil) })
        return menu
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImages(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedImages(sender)
        guard let first = urls.first, let model else { return false }
        if urls.count == 1, !model.isEditing {
            model.load(first)
        } else {
            WindowManager.shared.open(urls)
        }
        return true
    }

    private func droppedImages(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return isDirectory.boolValue || ImageFormats.isImage(url)
        }
    }
}

/// NSMenuItem that runs a closure.
@MainActor
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() {
        handler()
    }
}
