// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Switcher",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SwitcherCore",
            path: "Sources/Switcher"
        ),
        .executableTarget(
            name: "SwitcherApp",
            dependencies: ["SwitcherCore"],
            path: "Sources/SwitcherApp"
        ),
        .executableTarget(
            name: "SwitcherTests",
            dependencies: ["SwitcherCore"],
            path: "Sources/SwitcherTests"
        )
    ]
)
