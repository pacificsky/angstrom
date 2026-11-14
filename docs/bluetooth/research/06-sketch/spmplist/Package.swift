// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "probe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "probe",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", "Support/Info.plist"])
            ]
        )
    ]
)
