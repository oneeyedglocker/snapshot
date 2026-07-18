// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Snapshot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Snapshot",
            path: "Sources/Snapshot"
        )
    ]
)
