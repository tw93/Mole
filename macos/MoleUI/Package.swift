// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MoleUI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MoleUI", targets: ["MoleUI"]),
        .executable(name: "MolePrivilegedHelper", targets: ["MolePrivilegedHelper"])
    ],
    targets: [
        .executableTarget(
            name: "MoleUI",
            dependencies: ["MoleUICore"]
        ),
        .executableTarget(
            name: "MolePrivilegedHelper",
            dependencies: ["MoleUIPrivileged"]
        ),
        .target(
            name: "MoleUIPrivileged"
        ),
        .target(
            name: "MoleUICore",
            dependencies: ["MoleUIPrivileged"]
        ),
        .testTarget(
            name: "MoleUITests",
            dependencies: ["MoleUICore", "MoleUIPrivileged"]
        )
    ]
)
