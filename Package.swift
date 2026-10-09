// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dimmer",
    defaultLocalization: "en-GB",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Dimmer", targets: ["Dimmer"])],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Dimmer",
            dependencies: [.product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")],
            path: "Sources/Dimmer",
            resources: [.process("Resources")],
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
