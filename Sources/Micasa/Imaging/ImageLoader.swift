import CoreGraphics
import Foundation
import ImageIO

/// Facts about an image file that the viewer shows and uses for layout.
struct ImageInfo {
    var url: URL
    var typeIdentifier: String?
    /// Pixel size after EXIF orientation is applied.
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64
    var hasAlpha: Bool
    var isAnimated: Bool
    var frameCount: Int
    var camera: String?
    var exposure: String?
    var dateTaken: String?

    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    var megapixels: Double { Double(pixelWidth * pixelHeight) / 1_000_000 }
}

struct AnimationFrames {
    var images: [CGImage]
    /// Seconds each frame stays on screen.
    var delays: [Double]
}

enum ImageLoader {
    private static func source(for url: URL) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateWithURL(url as CFURL, options)
    }

    static func probe(_ url: URL) -> ImageInfo? {
        guard let src = source(for: url), CGImageSourceGetCount(src) > 0 else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        var width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        if (5...8).contains(orientation) { swap(&width, &height) }

        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let count = CGImageSourceGetCount(src)
        let animated = count > 1 && frameDelay(props) != nil

        var camera: String?
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
            let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
            if let model, let make, !model.lowercased().hasPrefix(make.lowercased()) {
                camera = "\(make) \(model)"
            } else {
                camera = model ?? make
            }
        }

        var exposure: String?
        var dateTaken: String?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var parts: [String] = []
            if let f = exif[kCGImagePropertyExifFNumber] as? Double { parts.append(String(format: "ƒ/%.1f", f)) }
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
                parts.append(t >= 1 ? String(format: "%.1fs", t) : "1/\(Int((1 / t).rounded()))s")
            }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { parts.append("ISO \(iso)") }
            if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { parts.append(String(format: "%.0f mm", focal)) }
            exposure = parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
            dateTaken = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        }

        return ImageInfo(
            url: url,
            typeIdentifier: CGImageSourceGetType(src) as String?,
            pixelWidth: width,
            pixelHeight: height,
            fileSize: fileSize,
            hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false,
            isAnimated: animated,
            frameCount: count,
            camera: camera,
            exposure: exposure,
            dateTaken: dateTaken
        )
    }

    /// Decodes one frame with EXIF orientation applied. `maxPixelSize == nil` means full resolution.
    static func decode(_ url: URL, maxPixelSize: Int? = nil, index: Int = 0) -> CGImage? {
        guard let src = source(for: url) else { return nil }
        return decode(src, maxPixelSize: maxPixelSize, index: index)
    }

    private static func decode(_ src: CGImageSource, maxPixelSize: Int?, index: Int) -> CGImage? {
        var limit = maxPixelSize
        if limit == nil {
            let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            limit = max(w, h)
        }
        guard let limit, limit > 0 else {
            return CGImageSourceCreateImageAtIndex(src, index, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, index, options as CFDictionary)
    }

    /// Decodes every frame of an animated GIF / APNG / WebP / HEICS.
    /// Returns nil when the animation would use too much memory; the viewer then shows frame 0.
    static func decodeAnimation(_ url: URL, maxPixelSize: Int, memoryBudget: Int = 1 << 30) -> AnimationFrames? {
        guard let src = source(for: url) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 1, count <= 5000 else { return nil }

        var images: [CGImage] = []
        var delays: [Double] = []
        var bytes = 0
        images.reserveCapacity(count)
        for index in 0..<count {
            guard let frame = decode(src, maxPixelSize: maxPixelSize, index: index) else { continue }
            bytes += frame.bytesPerRow * frame.height
            if bytes > memoryBudget { return nil }
            let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
            images.append(frame)
            delays.append(max(0.02, frameDelay(props) ?? 0.1))
        }
        return images.count > 1 ? AnimationFrames(images: images, delays: delays) : nil
    }

    /// Frame delay for the animated containers ImageIO knows about.
    private static func frameDelay(_ props: [CFString: Any]) -> Double? {
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime)
        ]
        for (dictKey, unclamped, clamped) in containers {
            guard let dict = props[dictKey] as? [CFString: Any] else { continue }
            if let value = dict[unclamped] as? Double, value > 0 { return value }
            if let value = dict[clamped] as? Double { return value }
        }
        return nil
    }
}
