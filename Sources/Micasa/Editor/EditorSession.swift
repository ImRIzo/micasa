import CoreGraphics
import Foundation
import Observation

enum EditorTool: String, CaseIterable, Identifiable {
    case adjust, crop, looks, export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adjust: "Adjust"
        case .crop: "Crop"
        case .looks: "Looks"
        case .export: "Export"
        }
    }

    var subtitle: String {
        switch self {
        case .adjust: "Light, color and detail"
        case .crop: "Frame, straighten and mirror"
        case .looks: "One-click non-destructive styles"
        case .export: "Format, size and quality"
        }
    }

    var systemImage: String {
        switch self {
        case .adjust: "slider.horizontal.3"
        case .crop: "crop"
        case .looks: "camera.filters"
        case .export: "square.and.arrow.up"
        }
    }
}

/// Edit state for one open image: parameters, undo history, crop draft and the live preview.
@MainActor
@Observable
final class EditorSession {
    private(set) var url: URL?
    private(set) var sourcePixelSize: CGSize = .zero
    private(set) var hasAlpha = false
    /// Downscaled, upright copy of the original that previews are rendered from.
    private(set) var sourcePreview: CGImage?
    /// The latest rendered preview of `params`.
    private(set) var preview: CGImage?

    // Explicit accessors instead of didSet so @Observable tracking stays straightforward.
    private var storedParams = EditParameters()
    var params: EditParameters {
        get { storedParams }
        set {
            guard newValue != storedParams else { return }
            storedParams = newValue
            scheduleRender()
        }
    }
    private(set) var savedParams = EditParameters()
    private var undoStack: [EditParameters] = []
    private var redoStack: [EditParameters] = []
    @ObservationIgnored private var changeStart: EditParameters?

    private var storedTool: EditorTool = .adjust
    var tool: EditorTool {
        get { storedTool }
        set {
            storedTool = newValue
            if newValue != .crop, isCropping { cancelCrop() }
        }
    }

    private(set) var isCropping = false
    var draftCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private(set) var cropAspect: CropAspect = .free

    var compareOriginal = false
    /// Crop frame when the current drag began (crop overlay gesture state).
    @ObservationIgnored var cropDragStart: CGRect?
    /// Text in the custom aspect-ratio fields.
    var customAspectWidth = "5"
    var customAspectHeight = "4"
    var exportOptions = ExportOptions()
    var isExporting = false
    var status: String?
    private(set) var activeLook: Look?

    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var renderInFlight = false
    @ObservationIgnored private var renderPending = false

    var isDirty: Bool { params != savedParams }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Full-resolution size of what the editor currently shows (crop excluded while cropping).
    var outputSize: CGSize {
        EditRenderer.shared.outputSize(for: params, inputSize: sourcePixelSize, includeCrop: !isCropping)
    }

    /// Full-resolution size after rotation, before cropping.
    var geometrySize: CGSize {
        EditRenderer.shared.outputSize(for: params, inputSize: sourcePixelSize, includeCrop: false)
    }

    /// Size of the saved file for the current export options.
    var exportPixelSize: CGSize {
        let size = EditRenderer.shared.outputSize(for: params, inputSize: sourcePixelSize)
        let scale = exportOptions.scale
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    // MARK: Session

    func begin(url: URL, info: ImageInfo, previewLimit: Int) {
        end()
        let id = UUID()
        sessionID = id
        self.url = url
        sourcePixelSize = info.pixelSize
        hasAlpha = info.hasAlpha
        Task {
            let source = await Task.detached(priority: .userInitiated) {
                ImageLoader.decode(url, maxPixelSize: previewLimit)
            }.value
            guard self.sessionID == id else { return }
            self.sourcePreview = source
            self.scheduleRender()
        }
    }

    func end() {
        sessionID = UUID()
        url = nil
        sourcePreview = nil
        preview = nil
        params = .identity
        savedParams = .identity
        undoStack.removeAll()
        redoStack.removeAll()
        changeStart = nil
        isCropping = false
        draftCrop = EditParameters.identity.crop
        cropAspect = .free
        compareOriginal = false
        tool = .adjust
        status = nil
        activeLook = nil
        isExporting = false
        renderPending = false
    }

    func markSaved() {
        savedParams = params
    }

    // MARK: Rendering

    private func scheduleRender() {
        guard let source = sourcePreview else { return }
        if renderInFlight {
            renderPending = true
            return
        }
        renderInFlight = true
        let id = sessionID
        let p = params
        let includeCrop = !isCropping
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                EditRenderer.shared.renderPreview(p, source: source, includeCrop: includeCrop)
            }.value
            self.renderInFlight = false
            guard self.sessionID == id else { return }
            self.preview = result
            if self.renderPending {
                self.renderPending = false
                self.scheduleRender()
            }
        }
    }

    // MARK: Undo

    /// Call when a slider drag starts; `endChange` records one undo step for the whole drag.
    func beginChange() {
        if changeStart == nil { changeStart = params }
    }

    func endChange() {
        if let start = changeStart, start != params {
            pushUndo(start)
            activeLook = nil
        }
        changeStart = nil
    }

    func commit(_ new: EditParameters) {
        guard new != params else { return }
        pushUndo(params)
        params = new
    }

    private func pushUndo(_ p: EditParameters) {
        undoStack.append(p)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(params)
        params = previous
        draftCrop = params.crop
        activeLook = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(params)
        params = next
        draftCrop = params.crop
        activeLook = nil
    }

    // MARK: Adjustments

    func resetValue(_ keyPath: WritableKeyPath<EditParameters, Double>) {
        var p = params
        p[keyPath: keyPath] = 0
        commit(p)
        activeLook = nil
    }

    func resetAdjustments() {
        commit(params.withoutAdjustments())
        activeLook = nil
    }

    func resetAll() {
        if isCropping { cancelCrop() }
        commit(.identity)
        draftCrop = params.crop
        activeLook = nil
    }

    func apply(_ look: Look) {
        commit(look.apply(to: params))
        activeLook = look
    }

    // MARK: Crop and geometry

    func beginCrop() {
        if tool != .crop { tool = .crop }
        guard !isCropping else { return }
        draftCrop = params.crop
        isCropping = true
        scheduleRender()
    }

    func applyCrop() {
        guard isCropping else { return }
        var p = params
        p.crop = clampedCrop(draftCrop)
        isCropping = false
        if p != params {
            commit(p)
        } else {
            scheduleRender()
        }
    }

    func cancelCrop() {
        guard isCropping else { return }
        draftCrop = params.crop
        isCropping = false
        scheduleRender()
    }

    func resetCropFrame() {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let ratio = cropAspect.ratio(imageSize: sourceAspectSize) {
            draftCrop = fitted(ratio: ratio, in: full)
        } else {
            draftCrop = full
        }
    }

    func setAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        if !isCropping { beginCrop() }
        if let ratio = aspect.ratio(imageSize: sourceAspectSize) {
            draftCrop = fitted(ratio: ratio, in: draftCrop)
        }
    }

    /// "Original" keeps the photo's own proportions regardless of rotation.
    private var sourceAspectSize: CGSize {
        params.normalizedTurns % 2 == 1
            ? CGSize(width: sourcePixelSize.height, height: sourcePixelSize.width)
            : sourcePixelSize
    }

    /// Width/height of the crop in normalized units for a pixel aspect ratio.
    func normalizedAspect(for ratio: Double) -> Double {
        let g = geometrySize
        guard g.width > 0 else { return ratio }
        return ratio * g.height / g.width
    }

    func fitted(ratio: Double, in rect: CGRect) -> CGRect {
        let a = normalizedAspect(for: ratio)
        var w = rect.width, h = rect.height
        if w / max(h, 0.0001) > a { w = h * a } else { h = w / a }
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    func clampedCrop(_ rect: CGRect) -> CGRect {
        var r = rect.standardized
        r.size.width = min(max(r.width, 0.01), 1)
        r.size.height = min(max(r.height, 0.01), 1)
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return r
    }

    /// Rotates what is on screen by 90°. The crop frame turns with the image.
    func rotate(clockwise: Bool) {
        var p = params
        var delta = clockwise ? 1 : -1
        // Mirroring is applied after rotation, so one mirror reverses the visible direction.
        if p.flipHorizontal != p.flipVertical { delta = -delta }
        p.quarterTurns = ((p.quarterTurns + delta) % 4 + 4) % 4
        p.crop = Self.rotated(p.crop, clockwise: clockwise)
        draftCrop = Self.rotated(draftCrop, clockwise: clockwise)
        commit(p)
    }

    func mirror(horizontal: Bool) {
        var p = params
        if horizontal {
            p.flipHorizontal.toggle()
            p.crop.origin.x = 1 - p.crop.maxX
            draftCrop.origin.x = 1 - draftCrop.maxX
        } else {
            p.flipVertical.toggle()
            p.crop.origin.y = 1 - p.crop.maxY
            draftCrop.origin.y = 1 - draftCrop.maxY
        }
        commit(p)
    }

    func resetGeometry() {
        var p = params
        p.quarterTurns = 0
        p.flipHorizontal = false
        p.flipVertical = false
        p.crop = EditParameters.identity.crop
        draftCrop = p.crop
        commit(p)
    }

    private static func rotated(_ r: CGRect, clockwise: Bool) -> CGRect {
        clockwise
            ? CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
            : CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
    }
}
