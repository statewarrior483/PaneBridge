// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaneBridge",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Prebuilt Google WebRTC (libwebrtc) for the low-latency UDP video path.
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "155.0.0"),
    ],
    targets: [
        // Small Objective-C wrapper around macOS's private CGVirtualDisplay API.
        .target(
            name: "VirtualDisplayKit",
            path: "Sources/VirtualDisplayKit",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "PaneBridge",
            dependencies: ["VirtualDisplayKit", .product(name: "WebRTC", package: "WebRTC")],
            path: "Sources/PaneBridge",
            resources: [.copy("Resources/client.html")],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                // WebRTC.framework is embedded in PaneBridge.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
