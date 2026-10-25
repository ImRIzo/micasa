import CoreGraphics
import Foundation

/// Non-destructive edit state. Mirrors Licasa's ImageEditParameters.
struct EditParameters: Equatable, Codable {
    // Light (-1...1)
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    // Color (-1...1)
    var saturation = 0.0
    var vibrance = 0.0
    var warmth = 0.0
    var tint = 0.0
    // Detail
    var sharpen = 0.0   // 0...1
    var soften = 0.0    // 0...0.35
    var vignette = 0.0  // 0...1

    // Geometry. Rotation is applied first (clockwise quarter turns), then mirroring,
    // then the crop. The crop rect is normalized (0...1) with a top-left origin,
    // measured in the rotated + mirrored image.
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

    static let identity = EditParameters()

    var hasColorAdjustments: Bool {
        var copy = self
        copy.quarterTurns = 0
        copy.flipHorizontal = false
        copy.flipVertical = false
        copy.crop = EditParameters.identity.crop
        return copy != .identity
    }

    var hasCrop: Bool {
        crop.minX > 0.0005 || crop.minY > 0.0005 || crop.width < 0.9995 || crop.height < 0.9995
    }

    var hasGeometry: Bool {
        normalizedTurns != 0 || flipHorizontal || flipVertical || hasCrop
    }

    var isIdentity: Bool { !hasColorAdjustments && !hasGeometry }

    var normalizedTurns: Int { ((quarterTurns % 4) + 4) % 4 }

    /// Clears color/detail adjustments but keeps rotation, mirroring and crop.
    func withoutAdjustments() -> EditParameters {
        var copy = EditParameters.identity
        copy.quarterTurns = quarterTurns
        copy.flipHorizontal = flipHorizontal
        copy.flipVertical = flipVertical
        copy.crop = crop
        return copy
    }
}

/// One-click styles from Licasa's "Looks" panel.
enum Look: String, CaseIterable, Identifiable {
    case mono, pop, vivid, cinema, soft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mono: "Mono"
        case .pop: "Pop"
        case .vivid: "Vivid"
        case .cinema: "Cinema"
        case .soft: "Soft"
        }
    }

    /// Applies the look on top of `base`'s geometry, replacing its adjustments.
    func apply(to base: EditParameters) -> EditParameters {
        var p = base.withoutAdjustments()
        switch self {
        case .mono:
            p.saturation = -1.0; p.contrast = 0.10; p.highlights = -0.08
        case .pop:
            p.exposure = 0.06; p.contrast = 0.22; p.saturation = 0.18
            p.vibrance = 0.20; p.warmth = 0.10; p.sharpen = 0.16
        case .cinema:
            p.exposure = -0.04; p.contrast = 0.16; p.highlights = -0.16; p.shadows = 0.10
            p.saturation = -0.10; p.tint = 0.08; p.vignette = 0.22
        case .soft:
            p.exposure = 0.08; p.contrast = -0.10; p.highlights = -0.08; p.shadows = 0.14
            p.saturation = -0.05; p.warmth = 0.06; p.soften = 0.08
        case .vivid:
            p.contrast = 0.12; p.highlights = -0.06; p.shadows = 0.08
            p.saturation = 0.12; p.vibrance = 0.32; p.sharpen = 0.12
        }
        return p
    }
}

/// Crop aspect-ratio presets from Licasa's crop panel.
enum CropAspect: Hashable, Identifiable {
    case free, original, square, ratio(Double, Double)

    var id: String { title }

    static let presets: [CropAspect] = [
        .free, .original, .square, .ratio(4, 3), .ratio(3, 2), .ratio(4, 5), .ratio(16, 9)
    ]

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case let .ratio(w, h): "\(Self.format(w)):\(Self.format(h))"
        }
    }

    /// Width / height in pixels, or nil for free-form.
    func ratio(imageSize: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original: imageSize.height > 0 ? imageSize.width / imageSize.height : nil
        case .square: 1
        case let .ratio(w, h): h > 0 ? w / h : nil
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2g", value)
    }
}
