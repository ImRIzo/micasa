import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case original, png, jpeg, heic, webp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .webp: "WebP"
        }
    }

    var fixedType: UTType? {
        switch self {
        case .original: nil
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .webp: .webP
        }
    }
}

struct ExportOptions: Equatable {
    var format: ExportFormat = .original
    /// Output scale relative to the edited size (0.1...1).
    var scale = 1.0
    /// Lossy quality (0.1...1).
    var quality = 0.95
}

enum ExportError: LocalizedError {
    case unreadable, renderFailed, writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "The original image could not be read."
        case .renderFailed: "The edited image could not be rendered."
        case .writeFailed: "The file could not be written."
        }
    }
}

enum ImageExporter {
    /// Formats this Mac can encode (WebP and HEIC encoding depend on the macOS version and hardware).
    static var availableFormats: [ExportFormat] {
        ExportFormat.allCases.filter { format in
            guard let type = format.fixedType else { return true }
            return ImageFormats.canWrite(type)
        }
    }

    /// The concrete file type for `format`. "Original" keeps the source type when macOS can
    /// write it (JPEG, PNG, HEIC, TIFF, GIF…) and falls back to JPEG otherwise (RAW, AVIF, JPEG XL).
    static func resolvedType(_ format: ExportFormat, source: URL, hasAlpha: Bool) -> UTType {
        if let type = format.fixedType { return type }
        if let sourceType = ImageFormats.type(of: source), ImageFormats.canWrite(sourceType),
           !sourceType.conforms(to: .rawImage) {
            return sourceType
        }
        return hasAlpha ? .png : .jpeg
    }

    static func supportsQuality(_ type: UTType) -> Bool {
        type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .webP)
            || type.identifier == "public.avif"
    }

    /// "photo (edited).jpg", "photo (edited 2).jpg", … next to the original. Never overwrites.
    static func suggestedURL(for source: URL, type: UTType) -> URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = type.preferredFilenameExtension ?? source.pathExtension
        var candidate = folder.appendingPathComponent("\(base) (edited)").appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (edited \(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Renders `params` on the full-resolution original and writes it to `destination`.
    static func export(source: URL, params: EditParameters, options: ExportOptions,
                       type: UTType, to destination: URL) throws {
        let renderer = EditRenderer.shared
        guard let input = renderer.fullResolutionInput(source) else { throw ExportError.unreadable }
        var image = renderer.apply(params, to: input)

        let scale = max(0.05, min(1.0, options.scale))
        if scale < 0.999 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0
            ])
            image = image.cropped(to: image.extent.integral)
        }
        if type.conforms(to: .jpeg) {
            // JPEG has no alpha channel: flatten transparent pixels onto white.
            image = image.composited(over: CIImage(color: .white).cropped(to: image.extent))
        }
        guard let cgImage = renderer.render(image) else { throw ExportError.renderFailed }

        var properties = sourceMetadata(source)
        if supportsQuality(type) {
            properties[kCGImageDestinationLossyCompressionQuality] = max(0.1, min(1.0, options.quality))
        }

        // Write next to the destination first, then move into place, so a failed
        // export never leaves a half-written file behind.
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(destination.pathExtension)")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, type.identifier as CFString, 1, nil) else {
            throw ExportError.writeFailed
        }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: temp)
            throw ExportError.writeFailed
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Camera metadata carried over from the original, with orientation reset
    /// (the pixels are already upright) and size fields dropped.
    private static func sourceMetadata(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        props[kCGImagePropertyOrientation] = 1
        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            props[kCGImagePropertyExifDictionary] = exif
        }
        // Container-specific dictionaries (GIF/PNG frame timing, RAW makernotes) don't apply to the new file.
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary,
                    kCGImagePropertyMakerAppleDictionary] {
            props.removeValue(forKey: key)
        }
        return props
    }
}
