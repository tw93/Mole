// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RoomyUI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RoomyUI", targets: ["RoomyUI"]),
        .executable(name: "RoomyPrivilegedHelper", targets: ["RoomyPrivilegedHelper"])
    ],
    targets: [
        .executableTarget(
            name: "RoomyUI",
            dependencies: ["RoomyUICore"]
        ),
        .executableTarget(
            name: "RoomyPrivilegedHelper",
            dependencies: ["RoomyUIPrivileged"]
        ),
        .target(
            name: "RoomyUIPrivileged"
        ),
        .target(
            name: "RoomyUICore",
            dependencies: ["RoomyUIPrivileged"]
        ),
        .testTarget(
            name: "RoomyUITests",
            dependencies: ["RoomyUICore", "RoomyUIPrivileged"]
        )
    ]
)
