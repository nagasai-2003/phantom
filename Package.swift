// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Phantom",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Phantom",
            path: "Sources/Phantom",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
