import Foundation

/// UserDefaults keys and defaults shared by @AppStorage views and non-view code.
enum SettingsKey {
    static let startInFullscreen = "startInFullscreen"
    static let fullscreenBackdropOpacity = "fullscreenBackdropOpacity"
    static let checkerboardEnabled = "checkerboardEnabled"
    static let playAnimations = "playAnimations"
    static let animationSpeed = "animationSpeed"
    static let smoothScaling = "smoothScaling"
    static let showInfoOverlay = "showInfoOverlay"
    static let motionAutoplay = "motionAutoplay"
    static let loopMotion = "loopMotion"
    static let reuseFullscreenViewer = "reuseFullscreenViewer"
}

enum AppSettings {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.startInFullscreen: true,
            SettingsKey.fullscreenBackdropOpacity: 0.88,
            SettingsKey.checkerboardEnabled: true,
            SettingsKey.playAnimations: true,
            SettingsKey.animationSpeed: 1.0,
            SettingsKey.smoothScaling: true,
            SettingsKey.showInfoOverlay: false,
            SettingsKey.motionAutoplay: false,
            SettingsKey.loopMotion: true,
            SettingsKey.reuseFullscreenViewer: true
        ])
    }

    private static var defaults: UserDefaults { .standard }

    static var startInFullscreen: Bool { defaults.bool(forKey: SettingsKey.startInFullscreen) }
    static var fullscreenBackdropOpacity: Double { defaults.double(forKey: SettingsKey.fullscreenBackdropOpacity) }
    static var checkerboardEnabled: Bool { defaults.bool(forKey: SettingsKey.checkerboardEnabled) }
    static var playAnimations: Bool { defaults.bool(forKey: SettingsKey.playAnimations) }
    static var animationSpeed: Double { max(0.25, min(4.0, defaults.double(forKey: SettingsKey.animationSpeed))) }
    static var smoothScaling: Bool { defaults.bool(forKey: SettingsKey.smoothScaling) }
    static var motionAutoplay: Bool { defaults.bool(forKey: SettingsKey.motionAutoplay) }
    static var loopMotion: Bool { defaults.bool(forKey: SettingsKey.loopMotion) }
    static var reuseFullscreenViewer: Bool { defaults.bool(forKey: SettingsKey.reuseFullscreenViewer) }
}
