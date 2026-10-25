// swift-tools-version:5.9
// Micasa — a native macOS (SwiftUI) port of Licasa (https://github.com/sanxchep/licasa).

import PackageDescription

let package = Package(
    name: "Micasa",
    platforms: [
        // macOS 14 Sonoma: needed for @Observable and for JPEG XL decoding in ImageIO.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Micasa", targets: ["Micasa"])
    ],
    targets: [
        .executableTarget(
            name: "Micasa",
            path: "Sources/Micasa",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreImage"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
