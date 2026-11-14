// swift-tools-version: 6.0
// Scratch verification package for research note 06 (NOT part of Angstrom).
// BTCore          ~ the CoreBluetooth-free seam + protocol logic (would live in `Angstrom`)
// BTCoreBluetooth ~ the thin CoreBluetooth adapter (would be the `AngstromBluetooth` product)
import PackageDescription
let package = Package(
    name: "btsketch",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BTCore", targets: ["BTCore"]),
        .library(name: "BTCoreBluetooth", targets: ["BTCoreBluetooth"]),
    ],
    targets: [
        .target(name: "BTCore"),
        .target(name: "BTCoreBluetooth", dependencies: ["BTCore"]),
        .testTarget(name: "BTCoreTests", dependencies: ["BTCore"]),
    ]
)
