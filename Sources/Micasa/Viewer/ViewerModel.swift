import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

enum ViewerMode {
    /// Image-sized view over a dimmed backdrop that covers the screen (Picasa style).
    case fullscreen
    /// A borderless window that is exactly the photo.
    case floating
}

/// State and behaviour of one viewer window.
@MainActor
@Observable
final class ViewerModel {
    // MARK: File

    private(set) var url: URL?
    private(set) var siblings: [URL] = []
    private(set) var info: ImageInfo?
    /// The decoded still. A screen-sized preview first, then full resolution.
    private(set) var image: CGImage?
    private(set) var isFullResolution = false
    private(set) var isLoading = false
    private(set) var loadError: String?

    // MARK: Animation (GIF, APNG, animated WebP/HEICS)

    private(set) var animation: AnimationFrames?
    private(set) var frameIndex = 0
    private(set) var isAnimationPlaying = false
    @ObservationIgnored private var animationTask: Task<Void, Never>?

    // MARK: Motion Photos / Live Photos

    private(set) var motion: MotionClip?
    private(set) var player: AVPlayer?
    private(set) var isMotionPlaying = false
    @ObservationIgnored private var playbackEndObserver: NSObjectProtocol?

    // MARK: View state

    private(set) var mode: ViewerMode
    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGSize = .zero
    private(set) var isFit = true
    private(set) var viewSize: CGSize = .zero
    var backingScale: CGFloat = 2
    private(set) var chromeVisible = true
    var showInfo = UserDefaults.standard.bool(forKey: SettingsKey.showInfoOverlay)
    var sideMenuOpen = false
    private(set) var toast: String?
    @ObservationIgnored private var chromeTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    var pointerOverControls = false

    // MARK: Editor

    let editor: EditorSession
    private(set) var isEditing = false

    // MARK: Hooks for the window controller

    @ObservationIgnored var onModeChange: ((ViewerMode) -> Void)?
    @ObservationIgnored var onFloatingZoom: ((CGFloat, CGPoint?) -> Void)?
    @ObservationIgnored var onContentSizeChange: (() -> Void)?
    @ObservationIgnored var onCloseRequest: (() -> Void)?
    @ObservationIgnored var presentingWindow: NSWindow?

    @ObservationIgnored private var loadToken = UUID()

    init(mode: ViewerMode) {
        self.mode = mode
        self.editor = EditorSession()
    }

    /// Long side, in pixels, of the largest attached screen. Previews are decoded at this size.
    static var screenPixelLimit: Int {
        let longest = NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 2560
        return Int(min(max(longest, 1600), 8192))
    }

    // MARK: Derived

    var index: Int {
        guard let url else { return 0 }
        return siblings.firstIndex(of: url) ?? 0
    }

    var title: String { url?.lastPathComponent ?? "Micasa" }

    /// Full-resolution pixel size of what is on screen.
    var contentPixelSize: CGSize {
        if isEditing {
            return editor.compareOriginal ? editor.sourcePixelSize : editor.outputSize
        }
        if let info { return info.pixelSize }
        if let image { return CGSize(width: image.width, height: image.height) }
        return .zero
    }

    var displayImage: CGImage? {
        if isEditing {
            if editor.compareOriginal { return editor.sourcePreview ?? image }
            return editor.preview ?? (editor.params.hasGeometry ? nil : image)
        }
        if let animation, !animation.images.isEmpty, isAnimationPlaying || frameIndex > 0 {
            return animation.images[min(frameIndex, animation.images.count - 1)]
        }
        return image
    }

    var hasTransparency: Bool { info?.hasAlpha ?? false }

    /// Zoom that fits the whole image, never enlarging past one image pixel per point.
    var fitZoom: CGFloat {
        let c = contentPixelSize
        guard c.width > 0, c.height > 0, viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min(viewSize.width / c.width, viewSize.height / c.height, 1)
    }

    /// One image pixel per screen pixel.
    var actualPixelsZoom: CGFloat { 1 / max(backingScale, 1) }

    var effectiveZoom: CGFloat {
        if mode == .floating && !isEditing {
            let c = contentPixelSize
            return c.width > 0 ? imageRect.width / c.width : 1
        }
        return isFit ? fitZoom : zoom
    }

    /// Zoom as a percentage of actual pixels.
    var zoomPercent: Int { Int((effectiveZoom / actualPixelsZoom * 100).rounded()) }

    /// Where the image is drawn, in view coordinates (top-left origin).
    var imageRect: CGRect {
        let c = contentPixelSize
        guard c.width > 0, c.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        if mode == .floating && !isEditing {
            let s = min(viewSize.width / c.width, viewSize.height / c.height)
            let size = CGSize(width: c.width * s, height: c.height * s)
            return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                          width: size.width, height: size.height)
        }
        let z = isFit ? fitZoom : zoom
        let size = CGSize(width: c.width * z, height: c.height * z)
        return CGRect(x: viewSize.width / 2 + offset.width - size.width / 2,
                      y: viewSize.height / 2 + offset.height - size.height / 2,
                      width: size.width, height: size.height)
    }

    var canPan: Bool {
        let r = imageRect
        return mode == .fullscreen && (r.width > viewSize.width + 0.5 || r.height > viewSize.height + 0.5)
    }

    // MARK: Loading

    func load(_ newURL: URL) {
        let target = newURL.standardizedFileURL
        resetMedia()
        url = target
        // The previous photo stays on screen until the new preview is decoded (no flash).
        isFullResolution = false
        loadError = nil
        isLoading = true
        isFit = true
        offset = .zero
        presentingWindow?.title = target.lastPathComponent

        let token = UUID()
        loadToken = token
        let previewLimit = Self.screenPixelLimit
        let needsSiblings = !siblings.contains(target)

        Task {
            let (probe, preview, folder) = await Task.detached(priority: .userInitiated) {
                () -> (ImageInfo?, CGImage?, [URL]?) in
                let probe = ImageLoader.probe(target)
                let preview = ImageLoader.decode(target, maxPixelSize: previewLimit)
                let folder = needsSiblings ? ImageFormats.siblingImages(of: target) : nil
                return (probe, preview, folder)
            }.value
            guard self.loadToken == token else { return }
            if let folder { self.siblings = folder }
            self.isLoading = false
            guard let probe, let preview else {
                self.info = nil
                self.image = nil
                self.loadError = "Micasa can't open “\(target.lastPathComponent)”."
                return
            }
            self.info = probe
            self.image = preview
            let longSide = max(probe.pixelWidth, probe.pixelHeight)
            self.isFullResolution = longSide <= max(preview.width, preview.height)
            self.onContentSizeChange?()
            self.loadExtras(for: target, info: probe, previewLimit: previewLimit, token: token)
        }
    }

    /// Full resolution, animation frames and the motion clip, after the first preview is up.
    private func loadExtras(for target: URL, info: ImageInfo, previewLimit: Int, token: UUID) {
        if info.isAnimated {
            Task {
                let frames = await Task.detached(priority: .utility) {
                    ImageLoader.decodeAnimation(target, maxPixelSize: previewLimit)
                }.value
                guard self.loadToken == token, let frames else { return }
                self.animation = frames
                if AppSettings.playAnimations { self.startAnimation() }
            }
        } else if !isFullResolution {
            // Very large images are capped so a 200-megapixel scan doesn't take gigabytes.
            let cap: Int? = info.megapixels > 150 ? 16_384 : nil
            Task {
                let full = await Task.detached(priority: .utility) {
                    ImageLoader.decode(target, maxPixelSize: cap)
                }.value
                guard self.loadToken == token, let full else { return }
                self.image = full
                self.isFullResolution = true
            }
        }

        Task {
            let clip = await Task.detached(priority: .utility) {
                MotionPhotoDetector.detect(target)
            }.value
            guard self.loadToken == token else {
                clip?.cleanUp()
                return
            }
            self.motion = clip
            if clip != nil, AppSettings.motionAutoplay { self.playMotion() }
        }
    }

    func reloadSiblings() {
        guard let url else { return }
        siblings = ImageFormats.siblingImages(of: url)
    }

    // MARK: Browsing

    func browse(_ step: Int) {
        guard !isEditing, siblings.count > 1 else { return }
        let next = ((index + step) % siblings.count + siblings.count) % siblings.count
        load(siblings[next])
    }

    func moveToTrash() {
        guard let url, !isEditing else { return }
        let name = url.lastPathComponent
        let position = index
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            showToast("Couldn't move “\(name)” to the Trash.")
            return
        }
        siblings.removeAll { $0 == url }
        showToast("Moved “\(name)” to the Trash")
        if siblings.isEmpty {
            onCloseRequest?()
        } else {
            load(siblings[min(position, siblings.count - 1)])
        }
    }

    func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Zoom and pan

    func viewSizeChanged(_ size: CGSize) {
        guard size != viewSize else { return }
        viewSize = size
        clampOffset()
    }

    func zoom(by factor: CGFloat, at point: CGPoint? = nil) {
        if mode == .floating && !isEditing {
            onFloatingZoom?(factor, point)
            return
        }
        let old = effectiveZoom
        let minZoom = max(0.01, fitZoom * 0.25)
        let maxZoom = actualPixelsZoom * 32
        let new = min(max(old * factor, minZoom), maxZoom)
        guard abs(new - old) > 0.00001 else { return }

        let anchor = point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let center = CGPoint(x: viewSize.width / 2 + offset.width, y: viewSize.height / 2 + offset.height)
        let ratio = new / old
        let newCenter = CGPoint(x: anchor.x - (anchor.x - center.x) * ratio,
                                y: anchor.y - (anchor.y - center.y) * ratio)
        zoom = new
        isFit = false
        offset = CGSize(width: newCenter.x - viewSize.width / 2, height: newCenter.y - viewSize.height / 2)
        if abs(new - fitZoom) < 0.0005 {
            fit()
        } else {
            clampOffset()
        }
    }

    func fit() {
        if mode == .floating && !isEditing {
            onFloatingZoom?(0, nil)  // 0 = restore the default floating size
            return
        }
        isFit = true
        offset = .zero
    }

    func actualPixels() {
        if mode == .floating && !isEditing {
            onFloatingZoom?(actualPixelsZoom / max(effectiveZoom, 0.0001), nil)
            return
        }
        zoom = actualPixelsZoom
        isFit = abs(actualPixelsZoom - fitZoom) < 0.0005
        offset = .zero
        clampOffset()
    }

    func pan(by delta: CGSize) {
        guard canPan else { return }
        if isFit { zoom = fitZoom; isFit = false }
        offset.width += delta.width
        offset.height += delta.height
        clampOffset()
    }

    private func clampOffset() {
        guard !isFit else { offset = .zero; return }
        let r = imageRect
        let maxX = max(0, (r.width - viewSize.width) / 2)
        let maxY = max(0, (r.height - viewSize.height) / 2)
        offset.width = min(max(offset.width, -maxX), maxX)
        offset.height = min(max(offset.height, -maxY), maxY)
    }

    // MARK: Modes

    func setMode(_ newMode: ViewerMode) {
        guard newMode != mode else { return }
        if newMode == .floating && isEditing {
            showToast("Close the editor first")
            return
        }
        mode = newMode
        sideMenuOpen = false
        isFit = true
        offset = .zero
        chromeVisible = true
        onModeChange?(newMode)
        noteActivity()
    }

    func toggleMode() {
        setMode(mode == .fullscreen ? .floating : .fullscreen)
    }

    // MARK: Chrome

    /// Shows the overlay controls and hides them again after a pause.
    func noteActivity() {
        chromeVisible = true
        chromeTask?.cancel()
        chromeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.pointerOverControls && !self.isEditing && !self.sideMenuOpen {
                self.chromeVisible = false
                if self.mode == .fullscreen { NSCursor.setHiddenUntilMouseMoves(true) }
            }
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard let self, !Task.isCancelled, self.toast == text else { return }
            self.toast = nil
        }
    }

    // MARK: Animation

    func startAnimation() {
        guard let animation, animation.images.count > 1 else { return }
        animationTask?.cancel()
        isAnimationPlaying = true
        animationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let frames = self.animation else { return }
                let delay = frames.delays[min(self.frameIndex, frames.delays.count - 1)] / AppSettings.animationSpeed
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.01) * 1_000_000_000))
                if Task.isCancelled { return }
                self.frameIndex = (self.frameIndex + 1) % frames.images.count
            }
        }
    }

    func stopAnimation() {
        animationTask?.cancel()
        animationTask = nil
        isAnimationPlaying = false
    }

    // MARK: Motion

    var hasPlayableMedia: Bool { motion != nil || (animation?.images.count ?? 0) > 1 }

    func togglePlayback() {
        if motion != nil {
            isMotionPlaying ? stopMotion() : playMotion()
        } else if animation != nil {
            isAnimationPlaying ? stopAnimation() : startAnimation()
        }
    }

    func playMotion() {
        guard let motion, !isEditing else { return }
        if player == nil {
            let newPlayer = AVPlayer(url: motion.videoURL)
            newPlayer.actionAtItemEnd = .pause
            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: newPlayer.currentItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.motionDidEnd() }
            }
            player = newPlayer
        }
        player?.seek(to: .zero)
        player?.play()
        isMotionPlaying = true
    }

    func stopMotion() {
        player?.pause()
        isMotionPlaying = false
    }

    private func motionDidEnd() {
        if AppSettings.loopMotion && isMotionPlaying {
            player?.seek(to: .zero)
            player?.play()
        } else {
            isMotionPlaying = false
        }
    }

    func saveMotionVideo() {
        guard let motion, let url else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [motion.videoURL.pathExtension.lowercased() == "mov" ? .quickTimeMovie : .mpeg4Movie]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (motion)." + motion.videoURL.pathExtension
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: motion.videoURL, to: destination)
            showToast("Saved “\(destination.lastPathComponent)”")
            reloadSiblings()
        } catch {
            showToast("Couldn't save the video.")
        }
    }

    private func resetMedia() {
        stopAnimation()
        animation = nil
        frameIndex = 0
        stopMotion()
        if let observer = playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObserver = nil
        }
        player = nil
        motion?.cleanUp()
        motion = nil
    }

    // MARK: Editor

    func openEditor() {
        guard let url, let info, !isEditing, !isLoading else { return }
        if mode == .floating { setMode(.fullscreen) }
        stopAnimation()
        frameIndex = 0
        stopMotion()
        sideMenuOpen = false
        editor.begin(url: url, info: info, previewLimit: min(Self.screenPixelLimit, 3072))
        isEditing = true
        isFit = true
        offset = .zero
        chromeVisible = true
    }

    /// Closes the editor, asking first if there are unsaved changes. Returns false if the user cancels.
    @discardableResult
    func closeEditor() -> Bool {
        guard isEditing else { return true }
        if editor.isDirty {
            switch askAboutUnsavedEdits() {
            case .save:
                saveEditedCopy(saveAs: false, thenCloseEditor: true)
                return false
            case .discard:
                break
            case .cancel:
                return false
            }
        }
        editor.end()
        isEditing = false
        isFit = true
        offset = .zero
        noteActivity()
        return true
    }

    func toggleEditor() {
        if isEditing {
            closeEditor()
        } else {
            openEditor()
        }
    }

    private enum UnsavedChoice { case save, discard, cancel }

    private func askAboutUnsavedEdits() -> UnsavedChoice {
        let alert = NSAlert()
        alert.messageText = "Save your edits to “\(title)”?"
        alert.informativeText = "Micasa saves an edited copy next to the original. The original is never changed."
        alert.addButton(withTitle: "Save Copy")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Returns true when the window may close.
    func prepareToClose() -> Bool {
        if isEditing, !closeEditor() { return false }
        resetMedia()
        return true
    }

    // MARK: Saving

    func saveEditedCopy(saveAs: Bool, thenCloseEditor: Bool = false) {
        guard let url, let info else { return }
        if !isEditing && !saveAs {
            showToast("Nothing to save — press E to edit")
            return
        }
        guard !editor.isExporting else { return }
        let params = isEditing ? editor.params : .identity
        let options = isEditing ? editor.exportOptions : ExportOptions()
        let type = ImageExporter.resolvedType(options.format, source: url, hasAlpha: info.hasAlpha)

        var destination = ImageExporter.suggestedURL(for: url, type: type)
        if saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [type]
            panel.nameFieldStringValue = destination.lastPathComponent
            panel.directoryURL = url.deletingLastPathComponent()
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            if chosen.standardizedFileURL == url.standardizedFileURL {
                showToast("Choose a different name — the original is never overwritten")
                return
            }
            destination = chosen
        }

        editor.isExporting = true
        editor.status = "Saving…"
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    try ImageExporter.export(source: url, params: params, options: options,
                                             type: type, to: destination)
                    return nil
                } catch {
                    return error
                }
            }.value
            self.editor.isExporting = false
            if let error {
                self.editor.status = error.localizedDescription
                self.showToast("Couldn't save: \(error.localizedDescription)")
                return
            }
            self.editor.markSaved()
            self.editor.status = "Saved “\(destination.lastPathComponent)”"
            self.showToast("Saved “\(destination.lastPathComponent)”")
            self.reloadSiblings()
            if thenCloseEditor { self.closeEditor() }
        }
    }

    // MARK: Keyboard

    /// Handles plain keys (menu shortcuts with ⌘ are handled by the menu bar). Returns true if used.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) { return false }
        noteActivity()

        switch event.keyCode {
        case 53: // Esc
            handleEscape()
            return true
        case 123, 124, 125, 126: // ← → ↓ ↑
            let dx: CGFloat = event.keyCode == 123 ? -1 : (event.keyCode == 124 ? 1 : 0)
            let dy: CGFloat = event.keyCode == 126 ? -1 : (event.keyCode == 125 ? 1 : 0)
            if editor.isCropping && mods.contains(.option) {
                nudgeCrop(dx: dx, dy: dy, resize: mods.contains(.shift))
            } else if mods.contains(.control) {
                pan(by: CGSize(width: -dx * 48, height: -dy * 48))
            } else if dx != 0 {
                // In the editor, leave ←/→ to the focused control (sliders, text fields).
                guard !isEditing else { return false }
                browse(Int(dx))
            } else {
                zoom(by: dy < 0 ? 1.15 : 1 / 1.15)
            }
            return true
        case 36, 76: // Return, Enter
            if editor.isCropping { editor.applyCrop(); return true }
            return false
        case 49: // Space
            togglePlayback()
            return true
        default:
            break
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return false }
        if mods.contains(.control), isEditing, let n = Int(key), (1...4).contains(n) {
            editor.tool = EditorTool.allCases[n - 1]
            return true
        }
        switch key {
        case "f": fit()
        case "1": actualPixels()
        case "+", "=": zoom(by: 1.15)
        case "-", "_": zoom(by: 1 / 1.15)
        case "e": if !editor.isCropping { toggleEditor() }
        case "c": if isEditing { editor.beginCrop() }
        case "m":
            if mode == .fullscreen && !isEditing { sideMenuOpen.toggle() }
        case "i": showInfo.toggle()
        default: return false
        }
        return true
    }

    func handleEscape() {
        if editor.isCropping {
            editor.cancelCrop()
        } else if isEditing {
            closeEditor()
        } else if sideMenuOpen {
            sideMenuOpen = false
        } else if mode == .fullscreen {
            setMode(.floating)
        } else {
            onCloseRequest?()
        }
    }

    private func nudgeCrop(dx: CGFloat, dy: CGFloat, resize: Bool) {
        var r = editor.draftCrop
        let step: CGFloat = 0.005
        if resize {
            r.size.width += dx * step
            r.size.height += dy * step
        } else {
            r.origin.x += dx * step
            r.origin.y += dy * step
        }
        editor.draftCrop = editor.clampedCrop(r)
    }
}
