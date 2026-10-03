// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Snippy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Snippy",
            path: "Sources/Snippy",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
