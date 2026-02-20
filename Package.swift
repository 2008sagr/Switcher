// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Switcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Switcher",
            path: "Sources/Switcher"
        )
    ]
)
