// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Claudon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Claudon", targets: ["Claudon"]),
        .executable(name: "ClaudonWidget", targets: ["ClaudonWidget"]),
    ],
    targets: [
        .target(name: "ClaudonCore"),
        .target(name: "ClaudonUI", dependencies: ["ClaudonCore"]),
        .executableTarget(name: "Claudon", dependencies: ["ClaudonCore", "ClaudonUI"]),
        // The widget extension; scripts/build-app.sh wraps it in an .appex inside the app. Like
        // Xcode's extension targets, it starts in NSExtensionMain, which sets up the extension
        // before handing over to the @main widget bundle.
        .executableTarget(name: "ClaudonWidget", dependencies: ["ClaudonCore", "ClaudonUI"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .testTarget(name: "ClaudonCoreTests", dependencies: ["ClaudonCore"]),
    ],
    swiftLanguageModes: [.v5]
)
