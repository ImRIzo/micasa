import Foundation
import UniformTypeIdentifiers

/// A short video that belongs to a still photo.
struct MotionClip {
    enum Kind { case androidMotionPhoto, samsungMotionPhoto, appleLivePhoto }

    let kind: Kind
    let videoURL: URL
    /// True when the clip was extracted from the photo into a temporary file.
    let isTemporary: Bool
    /// Seconds into the clip that matches the still frame, when the file says so.
    let stillTime: Double?

    func cleanUp() {
        if isTemporary { try? FileManager.default.removeItem(at: videoURL) }
    }
}

/// Finds the video in Android/Pixel Motion Photos (Motion Photo format 1.0 and the legacy
/// MicroVideo tags), Samsung Motion Photos (SEF "MotionPhoto_Data" trailer), and the
/// paired .MOV of an Apple Live Photo.
enum MotionPhotoDetector {
    static func detect(_ url: URL) -> MotionClip? {
        if let live = appleLivePhoto(url) { return live }
        guard let type = ImageFormats.type(of: url),
              type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 64 else { return nil }

        let xmp = xmpPacket(in: data)
        let stillTime = xmp.flatMap { presentationTimestamp(in: $0) }

        if let xmp, let range = containerVideoRange(xmp: xmp, data: data) ?? microVideoRange(xmp: xmp, data: data),
           let clip = extract(data, range: range, kind: .androidMotionPhoto, stillTime: stillTime) {
            return clip
        }
        if let range = samsungVideoRange(data),
           let clip = extract(data, range: range, kind: .samsungMotionPhoto, stillTime: stillTime) {
            return clip
        }
        return nil
    }

    // MARK: Apple Live Photo

    private static func appleLivePhoto(_ url: URL) -> MotionClip? {
        let base = url.deletingPathExtension()
        for ext in ["MOV", "mov"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return MotionClip(kind: .appleLivePhoto, videoURL: candidate, isTemporary: false, stillTime: nil)
            }
        }
        return nil
    }

    // MARK: XMP

    private static func xmpPacket(in data: Data) -> String? {
        guard let start = data.range(of: Data("<x:xmpmeta".utf8)),
              let end = data.range(of: Data("</x:xmpmeta>".utf8), in: start.upperBound..<data.endIndex) else {
            return nil
        }
        return String(decoding: data[start.lowerBound..<end.upperBound], as: UTF8.self)
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        // Matches name="value" and <name>value</name>.
        let patterns = [
            "\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*\"([^\"]*)\"",
            "<\(NSRegularExpression.escapedPattern(for: name))>([^<]*)</"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let valueRange = Range(match.range(at: 1), in: text) {
                return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func presentationTimestamp(in xmp: String) -> Double? {
        for key in ["GCamera:MotionPhotoPresentationTimestampUs", "GCamera:MicroVideoPresentationTimestampUs"] {
            if let value = attribute(key, in: xmp), let us = Double(value), us >= 0 {
                return us / 1_000_000
            }
        }
        return nil
    }

    /// Motion Photo 1.0: a Container:Directory item with Semantic="MotionPhoto" whose
    /// Length counts back from the end of the file (plus any Padding).
    private static func containerVideoRange(xmp: String, data: Data) -> Range<Int>? {
        var searchStart = xmp.startIndex
        while let hit = xmp.range(of: "MotionPhoto\"", range: searchStart..<xmp.endIndex) {
            searchStart = hit.upperBound
            // The enclosing tag holds the item's attributes.
            let tagStart = xmp[..<hit.lowerBound].lastIndex(of: "<") ?? xmp.startIndex
            let tagEnd = xmp[hit.upperBound...].firstIndex(of: ">") ?? xmp.endIndex
            let tag = String(xmp[tagStart..<tagEnd])
            guard tag.contains("Semantic"),
                  let lengthText = attribute("Item:Length", in: tag), let length = Int(lengthText), length > 0 else {
                continue
            }
            let padding = attribute("Item:Padding", in: tag).flatMap(Int.init) ?? 0
            let end = data.count - padding
            let start = end - length
            guard start > 0, end <= data.count else { continue }
            return start..<end
        }
        return nil
    }

    /// Legacy Pixel MicroVideo: the video is the last MicroVideoOffset bytes of the file.
    private static func microVideoRange(xmp: String, data: Data) -> Range<Int>? {
        guard let text = attribute("GCamera:MicroVideoOffset", in: xmp),
              let offset = Int(text), offset > 0, offset < data.count else { return nil }
        return (data.count - offset)..<data.count
    }

    /// Samsung: the clip follows the "MotionPhoto_Data" marker in the SEF trailer.
    private static func samsungVideoRange(_ data: Data) -> Range<Int>? {
        let marker = Data("MotionPhoto_Data".utf8)
        let tailStart = max(data.startIndex, data.endIndex - 64 * 1024 * 1024)
        guard let hit = data.range(of: marker, options: .backwards, in: tailStart..<data.endIndex) else {
            return nil
        }
        // The video runs up to the SEF directory ("SEFH") when present, else to EOF.
        let end = data.range(of: Data("SEFH".utf8), options: .backwards, in: hit.upperBound..<data.endIndex)?
            .lowerBound ?? data.endIndex
        return hit.upperBound..<end
    }

    // MARK: Extraction

    private static func extract(_ data: Data, range: Range<Int>, kind: MotionClip.Kind,
                                stillTime: Double?) -> MotionClip? {
        guard range.lowerBound >= data.startIndex, range.upperBound <= data.endIndex, range.count > 16 else {
            return nil
        }
        var start = range.lowerBound
        // HEIC Motion Photos wrap the clip in an "mpvd" box.
        if data[(start + 4)..<(start + 8)] == Data("mpvd".utf8) { start += 8 }
        guard range.upperBound - start > 16, data[(start + 4)..<(start + 8)] == Data("ftyp".utf8) else {
            return nil
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MicasaMotion", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        do {
            try data[start..<range.upperBound].write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return MotionClip(kind: kind, videoURL: file, isTemporary: true, stillTime: stillTime)
    }
}
