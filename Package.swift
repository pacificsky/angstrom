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
        .library(name: "AngstromUI", targets: ["AngstromUI"]),
    ],
    targets: [
        .target(name: "Angstrom"),
        .target(name: "AngstromUI", dependencies: ["Angstrom"]),
        .testTarget(
            name: "AngstromTests",
            dependencies: ["Angstrom"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AngstromUITests",
            dependencies: ["AngstromUI"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
