import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Core Image implementation of Licasa's edit pipeline. Runs on the GPU through Metal.
/// Every resolution-dependent radius is relative to the image size, so a small preview
/// and the full-resolution export look the same.
final class EditRenderer {
    static let shared = EditRenderer()

    let outputColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    let context: CIContext

    private init() {
        context = CIContext(options: [
            .cacheIntermediates: false,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        ])
    }

    // MARK: Pipeline

    func apply(_ p: EditParameters, to input: CIImage, includeCrop: Bool = true) -> CIImage {
        var image = normalized(input)

        // Geometry: rotate clockwise, then mirror.
        for _ in 0..<p.normalizedTurns { image = normalized(image.oriented(.right)) }
        if p.flipHorizontal { image = normalized(image.oriented(.upMirrored)) }
        if p.flipVertical { image = normalized(image.oriented(.downMirrored)) }

        if includeCrop, p.hasCrop {
            let w = image.extent.width, h = image.extent.height
            let rect = CGRect(
                x: p.crop.minX * w,
                y: (1 - p.crop.maxY) * h,
                width: p.crop.width * w,
                height: p.crop.height * h
            ).integral.intersection(image.extent)
            if rect.width >= 1, rect.height >= 1 {
                image = normalized(image.cropped(to: rect))
            }
        }

        guard p.hasColorAdjustments else { return image }
        let extent = image.extent
        let shortSide = max(1, min(extent.width, extent.height))

        if p.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: p.exposure * 2.0])
        }

        // Recovery directions use the local-adaptive filter; the opposite directions use a tone curve.
        let highlightAmount = 1.0 + min(0, p.highlights)        // 0...1, lower pulls highlights down
        let shadowAmount = max(0, p.shadows)                    // 0...1, higher lifts shadows
        if highlightAmount < 1 || shadowAmount > 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": shadowAmount,
                kCIInputRadiusKey: shortSide * 0.01
            ])
        }
        let lift = max(0, p.highlights) * 0.10
        let crush = min(0, p.shadows) * 0.10
        if lift > 0 || crush < 0 {
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + crush),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + lift),
                "inputPoint4": CIVector(x: 1, y: 1)
            ])
        }

        if p.contrast != 0 || p.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.0 + p.contrast * 0.5,
                kCIInputSaturationKey: max(0, 1.0 + p.saturation),
                kCIInputBrightnessKey: 0.0
            ])
        }

        if p.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": p.vibrance])
        }

        // White balance as channel gains: warmth trades blue for red, tint trades green for magenta.
        if p.warmth != 0 || p.tint != 0 {
            let r = 1.0 + 0.12 * p.warmth + 0.05 * p.tint
            let g = 1.0 - 0.10 * p.tint
            let b = 1.0 - 0.12 * p.warmth + 0.05 * p.tint
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }

        if p.soften > 0 {
            image = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: p.soften * shortSide * 0.015])
                .cropped(to: extent)
        }

        if p.sharpen > 0 {
            image = image.clampedToExtent()
                .applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: max(0.8, shortSide * 0.0015),
                    kCIInputIntensityKey: p.sharpen * 1.2
                ])
                .cropped(to: extent)
        }

        if p.vignette > 0 {
            let diagonal = hypot(extent.width, extent.height)
            image = image.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: diagonal * 0.42,
                kCIInputIntensityKey: p.vignette,
                "inputFalloff": 0.6
            ])
        }

        return image.cropped(to: extent)
    }

    /// Size of the result of `apply` for an input of `size`, without rendering.
    func outputSize(for p: EditParameters, inputSize size: CGSize, includeCrop: Bool = true) -> CGSize {
        var s = p.normalizedTurns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
        if includeCrop, p.hasCrop {
            s = CGSize(width: (s.width * p.crop.width).rounded(), height: (s.height * p.crop.height).rounded())
        }
        return s
    }

    // MARK: Rendering

    func render(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: outputColorSpace)
    }

    func renderPreview(_ p: EditParameters, source: CGImage, includeCrop: Bool) -> CGImage? {
        render(apply(p, to: CIImage(cgImage: source), includeCrop: includeCrop))
    }

    /// Loads the original file at full resolution (RAW files are developed by Core Image).
    func fullResolutionInput(_ url: URL) -> CIImage? {
        if let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            return image
        }
        return ImageLoader.decode(url).map { CIImage(cgImage: $0) }
    }

    private func normalized(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        guard origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }
}
