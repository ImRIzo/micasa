import AppKit
import SwiftUI

/// Borderless window used for both viewer modes. Borderless windows can't become key
/// by default, and have no close button for ⌘W to press, so both are handled here.
final class ViewerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true {
            close()
        }
    }
}

/// Owns one viewer window and switches it between fullscreen and floating presentation.
@MainActor
final class ViewerController: NSObject, NSWindowDelegate {
    let model: ViewerModel
    let window: ViewerWindow
    /// The floating frame the user last had, restored when leaving fullscreen.
    private var savedFloatingFrame: NSRect?

    init(mode: ViewerMode) {
        model = ViewerModel(mode: mode)
        window = ViewerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.acceptsMouseMovedEvents = true
        window.tabbingMode = .disallowed
        window.animationBehavior = .documentWindow
        window.minSize = NSSize(width: 96, height: 96)

        let host = NSHostingView(rootView: ViewerView(model: model))
        // The window decides its own size; don't let SwiftUI's ideal sizes constrain it.
        host.sizingOptions = []
        window.contentView = host
        window.delegate = self

        model.presentingWindow = window
        model.onModeChange = { [weak self] mode in self?.applyMode(mode) }
        model.onFloatingZoom = { [weak self] factor, point in self?.floatingZoom(factor, at: point) }
        model.onContentSizeChange = { [weak self] in self?.contentSizeChanged() }
        model.onCloseRequest = { [weak self] in self?.window.performClose(nil) }
    }

    func show(_ url: URL, cascadeIndex: Int = 0) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        model.backingScale = screen?.backingScaleFactor ?? 2
        if model.mode == .floating, let screen {
            // Placeholder until the image size is known; cascaded so windows don't stack exactly.
            var frame = defaultFloatingFrame(content: CGSize(width: 640, height: 480), on: screen)
            frame.origin.x += CGFloat(cascadeIndex) * 28
            frame.origin.y -= CGFloat(cascadeIndex) * 28
            window.setFrame(frame, display: false)
            pendingCascade = cascadeIndex
        }
        applyMode(model.mode, screen: screen)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.load(url)
        model.noteActivity()
    }

    private var pendingCascade: Int?

    // MARK: Modes

    func applyMode(_ mode: ViewerMode, screen: NSScreen? = nil) {
        guard let screen = screen ?? window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        switch mode {
        case .fullscreen:
            if window.isVisible { savedFloatingFrame = window.frame }
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            window.hasShadow = false
            window.backgroundColor = NSColor.black.withAlphaComponent(AppSettings.fullscreenBackdropOpacity)
            window.setFrame(screen.frame, display: true)
        case .floating:
            window.backgroundColor = .clear
            window.hasShadow = true
            let content = model.contentPixelSize
            let frame = savedFloatingFrame
                ?? defaultFloatingFrame(content: content.width > 0 ? content : CGSize(width: 640, height: 480),
                                        on: screen)
            window.setFrame(frame, display: true, animate: window.isVisible)
            updateAspectRatio()
        }
        updatePresentationOptions()
    }

    /// Re-applies the backdrop when the opacity setting changes.
    func refreshAppearance() {
        if model.mode == .fullscreen {
            window.backgroundColor = NSColor.black.withAlphaComponent(AppSettings.fullscreenBackdropOpacity)
        }
    }

    private func defaultFloatingFrame(content: CGSize, on screen: NSScreen, center: CGPoint? = nil) -> NSRect {
        let visible = screen.visibleFrame
        let scale = min(visible.width * 0.75 / content.width, visible.height * 0.75 / content.height, 1)
        var size = CGSize(width: content.width * scale, height: content.height * scale)
        let longSide = max(size.width, size.height)
        if longSide < 200 {
            size = CGSize(width: size.width * 200 / longSide, height: size.height * 200 / longSide)
        }
        let c = center ?? CGPoint(x: visible.midX, y: visible.midY)
        return NSRect(x: (c.x - size.width / 2).rounded(), y: (c.y - size.height / 2).rounded(),
                      width: size.width.rounded(), height: size.height.rounded())
    }

    private func updateAspectRatio() {
        let content = model.contentPixelSize
        if model.mode == .floating, content.width > 0, content.height > 0 {
            window.contentAspectRatio = NSSize(width: content.width, height: content.height)
        } else {
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
        }
    }

    /// A new image arrived: in floating mode, reshape the window to its proportions.
    private func contentSizeChanged() {
        savedFloatingFrame = nil
        guard model.mode == .floating, let screen = window.screen ?? NSScreen.main else { return }
        let content = model.contentPixelSize
        guard content.width > 0, content.height > 0 else { return }
        var frame = defaultFloatingFrame(content: content, on: screen,
                                         center: CGPoint(x: window.frame.midX, y: window.frame.midY))
        if let cascade = pendingCascade {
            // First image of a cascaded window: place it relative to the screen, not the placeholder.
            frame = defaultFloatingFrame(content: content, on: screen)
            frame.origin.x += CGFloat(cascade) * 28
            frame.origin.y -= CGFloat(cascade) * 28
            pendingCascade = nil
        }
        window.setFrame(frame, display: true, animate: window.isVisible)
        updateAspectRatio()
    }

    /// Floating mode zooms by resizing the window around the pointer. A factor of 0 restores the default size.
    private func floatingZoom(_ factor: CGFloat, at point: CGPoint?) {
        guard model.mode == .floating, let screen = window.screen ?? NSScreen.main else { return }
        let content = model.contentPixelSize
        guard content.width > 0, content.height > 0 else { return }
        let frame = window.frame
        if factor == 0 {
            window.setFrame(defaultFloatingFrame(content: content, on: screen,
                                                 center: CGPoint(x: frame.midX, y: frame.midY)),
                            display: true, animate: true)
            return
        }
        let aspect = content.height / content.width
        let minWidth = 96 / min(1, aspect)
        let maxWidth = screen.frame.width * 6
        let newWidth = min(max(frame.width * factor, minWidth), maxWidth)
        let newHeight = newWidth * aspect
        guard abs(newWidth - frame.width) > 0.5 else { return }

        // Keep the point under the pointer fixed (view coordinates have a top-left origin).
        let anchor = point ?? CGPoint(x: frame.width / 2, y: frame.height / 2)
        let fx = anchor.x / frame.width
        let fy = anchor.y / frame.height
        let anchorScreenX = frame.minX + anchor.x
        let anchorScreenY = frame.maxY - anchor.y
        let newFrame = NSRect(x: anchorScreenX - fx * newWidth,
                              y: anchorScreenY + fy * newHeight - newHeight,
                              width: newWidth, height: newHeight)
        window.setFrame(newFrame.integral, display: true)
    }

    private func updatePresentationOptions() {
        guard window.isKeyWindow else { return }
        NSApp.presentationOptions = model.mode == .fullscreen ? [.autoHideDock, .autoHideMenuBar] : []
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        updatePresentationOptions()
    }

    func windowDidResignKey(_ notification: Notification) {
        if model.mode == .fullscreen, !(NSApp.keyWindow is ViewerWindow) {
            NSApp.presentationOptions = []
        }
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        model.backingScale = window.backingScaleFactor
    }

    func windowDidChangeScreen(_ notification: Notification) {
        model.backingScale = window.backingScaleFactor
        if model.mode == .fullscreen, let screen = window.screen, window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.prepareToClose()
    }

    func windowWillClose(_ notification: Notification) {
        if window.isKeyWindow || NSApp.keyWindow == nil {
            NSApp.presentationOptions = []
        }
        WindowManager.shared.controllerDidClose(self)
    }
}
