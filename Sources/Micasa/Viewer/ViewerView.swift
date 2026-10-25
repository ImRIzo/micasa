import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Root view of a viewer window: the photo, input handling, overlays and side panels.
@MainActor
struct ViewerView: View {
    @Bindable var model: ViewerModel
    @AppStorage(SettingsKey.checkerboardEnabled) var checkerboard = true
    @AppStorage(SettingsKey.smoothScaling) var smoothScaling = true

    var body: some View {
        HStack(spacing: 0) {
            canvas
            if model.isEditing {
                EditorPanel(model: model, editor: model.editor)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if model.sideMenuOpen && model.mode == .fullscreen {
                SideMenu(model: model)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.18), value: model.isEditing)
        .animation(.easeOut(duration: 0.18), value: model.sideMenuOpen)
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                photo
                EventCatcher(model: model)
                if model.editor.isCropping {
                    CropOverlay(editor: model.editor, imageRect: model.imageRect)
                }
                overlays(size: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { model.viewSizeChanged(geo.size) }
            .onChange(of: geo.size) { _, newSize in model.viewSizeChanged(newSize) }
        }
        .onContinuousHover { phase in
            if case .active = phase { model.noteActivity() }
        }
    }

    // MARK: Photo

    @ViewBuilder
    private var photo: some View {
        let rect = model.imageRect
        if let image = model.displayImage, rect.width > 0, rect.height > 0 {
            ZStack {
                if checkerboard && model.hasTransparency {
                    CheckerboardView()
                }
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(smoothScaling ? .high : .none)
                    .antialiased(smoothScaling)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        }

        if model.isMotionPlaying, let player = model.player, rect.width > 0 {
            MotionPlayerView(player: player)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }

        if model.displayImage == nil {
            Group {
                if let error = model.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .padding(12)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                } else if model.isLoading || model.isEditing {
                    ProgressView().controlSize(.small)
                }
            }
            .position(x: model.viewSize.width / 2, y: model.viewSize.height / 2)
            .allowsHitTesting(false)
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private func overlays(size: CGSize) -> some View {
        if model.mode == .fullscreen || model.isEditing {
            VStack(spacing: 0) {
                if model.chromeVisible || model.isEditing {
                    TopBar(model: model)
                        .padding(.top, 14)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                if model.chromeVisible && !model.editor.isCropping && !model.isEditing {
                    FullscreenToolbar(model: model)
                        .padding(.bottom, 26)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(.easeInOut(duration: 0.2), value: model.chromeVisible)
        } else {
            FloatingControls(model: model)
                .frame(width: size.width, height: size.height)
                .opacity(model.chromeVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: model.chromeVisible)
        }

        if model.showInfo, let info = model.info, size.width > 260 {
            VStack {
                Spacer()
                HStack {
                    InfoOverlay(info: info, index: model.index, count: model.siblings.count,
                                zoomPercent: model.zoomPercent, hasMotion: model.motion != nil)
                    Spacer()
                }
            }
            .padding(model.mode == .fullscreen ? 24 : 10)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
        }

        if let toast = model.toast {
            VStack {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, model.mode == .fullscreen ? 64 : 12)
                Spacer()
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

// MARK: - Supporting views

/// Light/dark checkerboard behind transparent pixels, drawn as a repeating tile
/// so it stays cheap even when a zoomed photo is many thousands of points wide.
@MainActor
struct CheckerboardView: View {
    private static let tile: CGImage? = {
        let cell = 8
        guard let ctx = CGContext(data: nil, width: cell * 2, height: cell * 2, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cell * 2, height: cell * 2))
        ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cell, height: cell))
        ctx.fill(CGRect(x: cell, y: cell, width: cell, height: cell))
        return ctx.makeImage()
    }()

    var body: some View {
        if let tile = Self.tile {
            Rectangle().fill(ImagePaint(image: Image(decorative: tile, scale: 1)))
        } else {
            Color(white: 0.7)
        }
    }
}

/// Plays a Motion Photo / Live Photo clip in an AVPlayerLayer.
@MainActor
struct MotionPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerLayer.videoGravity = .resizeAspect
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func makeBackingLayer() -> CALayer {
        playerLayer
    }
}

@MainActor
struct InfoOverlay: View {
    let info: ImageInfo
    let index: Int
    let count: Int
    let zoomPercent: Int
    let hasMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.url.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1)
            Text("\(info.pixelWidth) × \(info.pixelHeight)  ·  \(String(format: "%.1f", info.megapixels)) MP  ·  \(zoomPercent)%")
            Text([formatName, ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file)]
                .compactMap { $0 }.joined(separator: "  ·  "))
            if let camera = info.camera { Text(camera) }
            if let exposure = info.exposure { Text(exposure) }
            if let date = info.dateTaken { Text(date) }
            if count > 1 { Text("\(index + 1) of \(count)") }
            if hasMotion { Label("Motion photo", systemImage: "livephoto") }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.92))
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 320, alignment: .leading)
    }

    private var formatName: String? {
        guard let id = info.typeIdentifier, let type = UTType(id) else { return nil }
        if info.isAnimated { return "Animated \(type.preferredFilenameExtension?.uppercased() ?? "image")" }
        return type.localizedDescription ?? type.preferredFilenameExtension?.uppercased()
    }
}
