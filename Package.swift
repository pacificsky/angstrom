// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Angstrom",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "Angstrom", targets: ["Angstrom"]),
    ],
    targets: [
        .target(name: "Angstrom"),
        .testTarget(name: "AngstromTests", dependencies: ["Angstrom"]),
    ]
)
