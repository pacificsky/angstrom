// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Layout",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "CoreBT", targets: ["CoreBT"]),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "CoreBT", dependencies: ["Core"]),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ]
)
