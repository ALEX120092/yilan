// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VolumeMixer",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "VolumeMixer",
            path: "Sources/VolumeMixer"
        )
    ]
)
