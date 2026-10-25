import AppKit
import SwiftUI

/// Interactive crop frame drawn over the uncropped image while cropping.
/// The frame is stored normalized (0...1, top-left origin) in `editor.draftCrop`.
@MainActor
struct CropOverlay: View {
    @Bindable var editor: EditorSession
    /// Where the uncropped image is drawn, in view coordinates.
    let imageRect: CGRect

    private struct Handle: Identifiable {
        let id: Int
        let left, right, top, bottom: Bool
        var isCorner: Bool { (left || right) && (top || bottom) }
    }

    private static let handles: [Handle] = [
        Handle(id: 0, left: true, right: false, top: true, bottom: false),
        Handle(id: 1, left: false, right: false, top: true, bottom: false),
        Handle(id: 2, left: false, right: true, top: true, bottom: false),
        Handle(id: 3, left: false, right: true, top: false, bottom: false),
        Handle(id: 4, left: false, right: true, top: false, bottom: true),
        Handle(id: 5, left: false, right: false, top: false, bottom: true),
        Handle(id: 6, left: true, right: false, top: false, bottom: true),
        Handle(id: 7, left: true, right: false, top: false, bottom: false)
    ]

    private var cropRect: CGRect {
        let c = editor.draftCrop
        return CGRect(x: imageRect.minX + c.minX * imageRect.width,
                      y: imageRect.minY + c.minY * imageRect.height,
                      width: c.width * imageRect.width,
                      height: c.height * imageRect.height)
    }

    var body: some View {
        let rect = cropRect
        ZStack(alignment: .topLeading) {
            // Shield outside the frame.
            Path { path in
                path.addRect(imageRect)
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Rule-of-thirds grid and border.
            Path { path in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            // Drag inside the frame to move it.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: max(rect.width - 24, 1), height: max(rect.height - 24, 1))
                .gesture(moveGesture)
                .onHover { inside in inside ? NSCursor.openHand.push() : NSCursor.pop() }
                .position(x: rect.midX, y: rect.midY)

            ForEach(Self.handles) { handle in
                handleView(handle)
                    .gesture(resizeGesture(handle))
                    .position(handlePosition(handle, in: rect))
            }
        }
    }

    // MARK: Handles

    @ViewBuilder
    private func handleView(_ handle: Handle) -> some View {
        let horizontalEdge = (handle.top || handle.bottom) && !handle.isCorner
        let size = handle.isCorner ? CGSize(width: 16, height: 16)
            : (horizontalEdge ? CGSize(width: 28, height: 8) : CGSize(width: 8, height: 28))
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(width: size.width, height: size.height)
            .padding(8) // larger hit area
            .contentShape(Rectangle())
    }

    private func handlePosition(_ h: Handle, in rect: CGRect) -> CGPoint {
        let x = h.left ? rect.minX : (h.right ? rect.maxX : rect.midX)
        let y = h.top ? rect.minY : (h.bottom ? rect.maxY : rect.midY)
        return CGPoint(x: x, y: y)
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = editor.cropDragStart ?? editor.draftCrop
                if editor.cropDragStart == nil { editor.cropDragStart = start }
                var r = start
                r.origin.x += value.translation.width / max(imageRect.width, 1)
                r.origin.y += value.translation.height / max(imageRect.height, 1)
                r.origin.x = min(max(r.minX, 0), 1 - r.width)
                r.origin.y = min(max(r.minY, 0), 1 - r.height)
                editor.draftCrop = r
            }
            .onEnded { _ in editor.cropDragStart = nil }
    }

    private func resizeGesture(_ h: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = editor.cropDragStart ?? editor.draftCrop
                if editor.cropDragStart == nil { editor.cropDragStart = start }
                if let r = resized(start, handle: h,
                                   dx: value.translation.width / max(imageRect.width, 1),
                                   dy: value.translation.height / max(imageRect.height, 1)) {
                    editor.draftCrop = r
                }
            }
            .onEnded { _ in editor.cropDragStart = nil }
    }

    /// The frame after dragging handle `h` by (dx, dy) in normalized units, or nil if invalid.
    private func resized(_ start: CGRect, handle h: Handle, dx: CGFloat, dy: CGFloat) -> CGRect? {
        let minSize: CGFloat = 0.02
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if h.left { minX = min(max(0, start.minX + dx), maxX - minSize) }
        if h.right { maxX = max(min(1, start.maxX + dx), minX + minSize) }
        if h.top { minY = min(max(0, start.minY + dy), maxY - minSize) }
        if h.bottom { maxY = max(min(1, start.maxY + dy), minY + minSize) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        guard let ratio = editor.cropAspect.ratio(imageSize: aspectReferenceSize) else { return r }
        let a = editor.normalizedAspect(for: ratio) // normalized width / height

        if h.isCorner {
            // Follow whichever side moved more, derive the other from the ratio.
            let widthDriven = abs(dx) * a >= abs(dy) || !(h.top || h.bottom)
            if widthDriven { r.size.height = r.width / a } else { r.size.width = r.height * a }
            if h.left { r.origin.x = maxX - r.width }
            if h.top { r.origin.y = maxY - r.height }
        } else if h.left || h.right {
            r.size.height = r.width / a
            r.origin.y = start.midY - r.height / 2
        } else {
            r.size.width = r.height * a
            r.origin.x = start.midX - r.width / 2
        }

        let epsilon: CGFloat = 0.0001
        guard r.minX >= -epsilon, r.minY >= -epsilon, r.maxX <= 1 + epsilon, r.maxY <= 1 + epsilon,
              r.width >= minSize, r.height >= minSize else {
            return nil
        }
        return editor.clampedCrop(r)
    }

    /// "Original" means the photo's own proportions, following the rotation.
    private var aspectReferenceSize: CGSize {
        let s = editor.sourcePixelSize
        return editor.params.normalizedTurns % 2 == 1 ? CGSize(width: s.height, height: s.width) : s
    }
}
