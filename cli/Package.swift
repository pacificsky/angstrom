// swift-tools-version: 6.0
import PackageDescription

// A separate, nested SwiftPM package: the `angcli` wire-debugging tool. It is
// intentionally NOT part of the root Angstrom library build — apps depending on
// `Angstrom` never see this package or its `swift-argument-parser` dependency.
//
// The `.package(path: "..")` dependency always builds against the in-repo
// working tree (no version pin). Promotion to a standalone repo later is cheap:
// flip the path to a URL pin and `git subtree split` this folder.
let package = Package(
    name: "angcli",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "angcli",
            dependencies: [
                .product(name: "Angstrom", package: "Angstrom"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "angcliTests",
            dependencies: ["angcli"]
        ),
    ]
)
