// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DuoDisplay",
    platforms: [.macOS(.v14)],
    targets: [
        // Declarations for Apple's private CGVirtualDisplay API (lives in CoreGraphics).
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "DuoDisplay",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/DuoDisplay",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("SystemExtensions"),
            ]
        ),
        // Camera system extension: publishes the iMac camera as a camera on the MacBook.
        // build.sh wraps this executable into DuoDisplay.app/Contents/Library/SystemExtensions.
        .executableTarget(
            name: "DuoDisplayCamera",
            path: "Sources/DuoDisplayCamera",
            linkerSettings: [
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
    ]
)
