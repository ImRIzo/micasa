import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Settings window (⌘,).
@MainActor
struct SettingsView: View {
    var body: some View {
        Form {
            SettingsSections()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 520)
    }
}

/// Settings panel that slides in from the right of the fullscreen viewer (M).
@MainActor
struct SideMenu: View {
    let model: ViewerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                ChromeButton(systemImage: "xmark", help: "Close (M)", size: 26) { model.sideMenuOpen = false }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Form {
                SettingsSections()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(Color(white: 0.11).opacity(0.97))
        .onHover { model.pointerOverControls = $0 }
    }
}

@MainActor
struct SettingsSections: View {
    @AppStorage(SettingsKey.startInFullscreen) var startInFullscreen = true
    @AppStorage(SettingsKey.reuseFullscreenViewer) var reuseFullscreenViewer = true
    @AppStorage(SettingsKey.fullscreenBackdropOpacity) var backdropOpacity = 0.88
    @AppStorage(SettingsKey.showInfoOverlay) var showInfoOverlay = false
    @AppStorage(SettingsKey.smoothScaling) var smoothScaling = true
    @AppStorage(SettingsKey.checkerboardEnabled) var checkerboard = true
    @AppStorage(SettingsKey.playAnimations) var playAnimations = true
    @AppStorage(SettingsKey.animationSpeed) var animationSpeed = 1.0
    @AppStorage(SettingsKey.motionAutoplay) var motionAutoplay = false
    @AppStorage(SettingsKey.loopMotion) var loopMotion = true

    let defaultApp = DefaultAppHelper.shared

    var body: some View {
        Section("Viewer") {
            Toggle("Open photos in fullscreen", isOn: $startInFullscreen)
            Toggle("Reuse the fullscreen viewer for new photos", isOn: $reuseFullscreenViewer)
            LabeledContent("Backdrop") {
                HStack {
                    Slider(value: $backdropOpacity, in: 0.2...1)
                    Text("\(Int(backdropOpacity * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                }
            }
            Toggle("Show photo info for new windows", isOn: $showInfoOverlay)
        }

        Section("Display") {
            Toggle("Smooth image scaling", isOn: $smoothScaling)
            Toggle("Checkerboard behind transparency", isOn: $checkerboard)
        }

        Section("Animated images") {
            Toggle("Play GIF, APNG and WebP animations", isOn: $playAnimations)
            LabeledContent("Speed") {
                HStack {
                    Slider(value: $animationSpeed, in: 0.25...4, step: 0.25)
                    Text(String(format: "%.2g×", animationSpeed)).monospacedDigit().frame(width: 38, alignment: .trailing)
                }
            }
        }

        Section("Motion Photos and Live Photos") {
            Toggle("Play motion when a photo opens", isOn: $motionAutoplay)
            Toggle("Loop motion", isOn: $loopMotion)
        }

        Section("Default app") {
            Button("Make Micasa the default photo viewer") { defaultApp.makeDefaultViewer() }
            if let status = defaultApp.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }

        Section {
            Text("Micasa — a native macOS port of Licasa by Sanxchep Sharma (BSD 2-Clause). Reads \(ImageFormats.readableTypes.count) image formats through macOS ImageIO, including HEIC, AVIF, JPEG XL, JPEG 2000, WebP and camera RAW.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Sets Micasa as the default app for common photo types.
@MainActor
@Observable
final class DefaultAppHelper {
    static let shared = DefaultAppHelper()
    private(set) var status: String?

    func makeDefaultViewer() {
        let types: [UTType] = [.jpeg, .png, .heic, .heif, .tiff, .webP, .gif, .bmp, .rawImage]
            + [UTType("public.avif"), UTType("public.jpeg-xl"), UTType("public.jpeg-2000")].compactMap { $0 }
        let appURL = Bundle.main.bundleURL
        Task { @MainActor in
            var failed = 0
            for type in types {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
                } catch {
                    failed += 1
                }
            }
            self.status = failed == 0
                ? "Micasa now opens \(types.count) photo formats."
                : "Set for \(types.count - failed) of \(types.count) formats. Run Micasa from /Applications and try again."
        }
    }
}
