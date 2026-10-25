import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What this Mac's ImageIO can read and write. HEIC, AVIF, JPEG XL (macOS 14+),
/// JPEG 2000, WebP, TIFF, PNG/APNG, GIF and camera RAW all come from the system,
/// so no codec libraries need to be bundled.
enum ImageFormats {
    static let readableTypes: [UTType] = {
        let ids = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return ids
            .compactMap { UTType($0) }
            .filter { $0.conforms(to: .image) && !$0.conforms(to: .pdf) }
    }()

    static let writableTypeIDs: Set<String> = {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }()

    static func canWrite(_ type: UTType) -> Bool {
        writableTypeIDs.contains(type.identifier)
    }

    static func type(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension.lowercased())
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = type(of: url) else { return false }
        return readableTypes.contains { type.conforms(to: $0) }
    }

    /// Image files directly inside `folder`, in Finder order.
    static func images(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return items
            .filter { item in
                let isFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                return isFile && isImage(item)
            }
            .map(\.standardizedFileURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Image files in the same folder as `url` (including `url`), in Finder order.
    static func siblingImages(of url: URL) -> [URL] {
        let target = url.standardizedFileURL
        var result = Self.images(in: target.deletingLastPathComponent())
        if !result.contains(target) {
            result.append(target)
            result.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        return result
    }
}
