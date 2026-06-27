// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Angstrom",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "Angstrom", targets: ["Angstrom"]),
    ],
    targets: [
        .target(name: "Angstrom"),
        .testTarget(name: "AngstromTests", dependencies: ["Angstrom"]),
    ]
)
