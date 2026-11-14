// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaneBridge",
    platforms: [.macOS(.v13)],
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
            dependencies: ["VirtualDisplayKit"],
            path: "Sources/PaneBridge",
            resources: [.copy("Resources/client.html")],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
