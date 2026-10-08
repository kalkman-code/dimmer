// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dimmer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Dimmer", targets: ["Dimmer"])],
    targets: [
        .executableTarget(
            name: "Dimmer",
            path: "Sources/Dimmer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(name: "DimmerTests", dependencies: ["Dimmer"], path: "Tests/DimmerTests")
    ],
    swiftLanguageModes: [.v5]
)
