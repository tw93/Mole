// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MoleMenuBar",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "MoleMenuBarCore",
            path: "Sources/MoleMenuBarCore"
        ),
        .executableTarget(
            name: "MoleMenuBar",
            dependencies: ["MoleMenuBarCore"],
            path: "Sources/MoleMenuBar"
        ),
        .testTarget(
            name: "MoleMenuBarTests",
            dependencies: ["MoleMenuBarCore"],
            path: "Tests/MoleMenuBarTests"
        ),
    ]
)
