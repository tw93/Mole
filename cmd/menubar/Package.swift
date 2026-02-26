// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MoleMenuBar",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "MoleMenuBar",
            path: "Sources/MoleMenuBar"
        )
    ]
)
