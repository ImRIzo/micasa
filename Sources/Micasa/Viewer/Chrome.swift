import AppKit
import SwiftUI

/// Round icon button used on the viewer's overlay controls.
/// (No @State here: with the Command Line Tools and newer SDKs, @State is a macro whose
/// plugin only ships with full Xcode, so the views keep their state in the models instead.)
@MainActor
struct ChromeButton: View {
    let systemImage: String
    let help: String
    var size: CGFloat = 32
    var isActive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.44, weight: .medium))
                .frame(width: size, height: size)
        }
        .buttonStyle(ChromeButtonStyle(size: size, isActive: isActive))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
    }
}

struct ChromeButtonStyle: ButtonStyle {
    let size: CGFloat
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? Color.accentColor : Color.white)
            .background(
                Circle().fill(Color.white.opacity(configuration.isPressed ? 0.25 : (isActive ? 0.12 : 0)))
            )
            .contentShape(Circle())
    }
}

/// File name and position at the top of the fullscreen viewer.
@MainActor
struct TopBar: View {
    let model: ViewerModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if model.siblings.count > 1 {
                Text("\(model.index + 1) / \(model.siblings.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.isEditing && model.editor.isDirty {
                Text("Edited")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.35), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .onHover { model.pointerOverControls = $0 }
    }
}

/// Bottom toolbar of the fullscreen viewer.
@MainActor
struct FullscreenToolbar: View {
    let model: ViewerModel

    var body: some View {
        HStack(spacing: 4) {
            ChromeButton(systemImage: "chevron.left", help: "Previous photo (←)",
                         isEnabled: model.siblings.count > 1) { model.browse(-1) }
            ChromeButton(systemImage: "chevron.right", help: "Next photo (→)",
                         isEnabled: model.siblings.count > 1) { model.browse(1) }

            divider

            ChromeButton(systemImage: "minus.magnifyingglass", help: "Zoom out (−)") { model.zoom(by: 1 / 1.25) }
            Button {
                model.isFit ? model.actualPixels() : model.fit()
            } label: {
                Text(model.isFit ? "Fit" : "\(model.zoomPercent)%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .frame(minWidth: 46)
            }
            .buttonStyle(.plain)
            .help("Toggle fit (F) / actual pixels (1)")
            ChromeButton(systemImage: "plus.magnifyingglass", help: "Zoom in (+)") { model.zoom(by: 1.25) }

            divider

            if model.motion != nil {
                ChromeButton(systemImage: model.isMotionPlaying ? "stop.fill" : "livephoto.play",
                             help: "Play motion (Space)", isActive: model.isMotionPlaying) { model.togglePlayback() }
            } else if model.animation != nil {
                ChromeButton(systemImage: model.isAnimationPlaying ? "pause.fill" : "play.fill",
                             help: "Play / pause animation (Space)") { model.togglePlayback() }
            }
            ChromeButton(systemImage: "slider.horizontal.3", help: "Edit (E)", isEnabled: model.info != nil) {
                model.openEditor()
            }
            ChromeButton(systemImage: "info.circle", help: "Info (I)", isActive: model.showInfo) {
                model.showInfo.toggle()
            }
            ChromeButton(systemImage: "rectangle.on.rectangle", help: "Floating window (Esc)") {
                model.setMode(.floating)
            }
            ChromeButton(systemImage: "gearshape", help: "Settings (M)", isActive: model.sideMenuOpen) {
                model.sideMenuOpen.toggle()
            }

            divider

            ChromeButton(systemImage: "xmark", help: "Close (⌘W)") {
                model.presentingWindow?.performClose(nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .onHover { model.pointerOverControls = $0 }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 18).padding(.horizontal, 4)
    }
}

/// Hover controls on a floating window.
@MainActor
struct FloatingControls: View {
    let model: ViewerModel

    var body: some View {
        let compact = model.viewSize.width < 260 || model.viewSize.height < 160
        VStack(spacing: 0) {
            // Separate round buttons in the corners (like Picture in Picture), no bar across the photo.
            HStack(spacing: 6) {
                FloatButton(systemImage: "xmark", help: "Close (⌘W)") {
                    model.presentingWindow?.performClose(nil)
                }
                Spacer()
                if !compact {
                    FloatButton(systemImage: "slider.horizontal.3", help: "Edit (E)") { model.openEditor() }
                    FloatButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Fullscreen (double-click)") {
                        model.setMode(.fullscreen)
                    }
                }
            }
            .padding(10)

            Spacer()

            if !compact && (model.siblings.count > 1 || model.motion != nil) {
                HStack(spacing: 2) {
                    if model.siblings.count > 1 {
                        ChromeButton(systemImage: "chevron.left", help: "Previous (←)", size: 26) { model.browse(-1) }
                    }
                    if model.motion != nil {
                        ChromeButton(systemImage: model.isMotionPlaying ? "stop.fill" : "livephoto.play",
                                     help: "Play motion (Space)", size: 26) { model.togglePlayback() }
                    }
                    if model.siblings.count > 1 {
                        ChromeButton(systemImage: "chevron.right", help: "Next (→)", size: 26) { model.browse(1) }
                    }
                }
                .padding(3)
                .background(Color.black.opacity(0.45), in: Capsule())
                .padding(.bottom, 10)
                .onHover { model.pointerOverControls = $0 }
            }
        }
    }
}

/// Small dark circular button for floating windows.
@MainActor
struct FloatButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
