// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Claudon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Claudon", targets: ["Claudon"]),
    ],
    targets: [
        .target(name: "ClaudonCore"),
        .executableTarget(name: "Claudon", dependencies: ["ClaudonCore"]),
        .testTarget(name: "ClaudonCoreTests", dependencies: ["ClaudonCore"]),
    ],
    swiftLanguageModes: [.v5]
)
