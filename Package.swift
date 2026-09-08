// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "lowlight",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "lowlight", targets: ["lowlight"]),
        .library(name: "ModelChatCore", targets: ["ModelChatCore"]),
        .library(name: "ModelTransport", targets: ["ModelTransport"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/SwiftTUI/swift-tui",
            exact: "0.9.7"
        ),
    ],
    targets: [
        .target(name: "ModelTransport"),
        .target(
            name: "ModelChatCore",
            dependencies: ["ModelTransport"]
        ),
        .executableTarget(
            name: "lowlight",
            dependencies: [
                "ModelChatCore",
                .product(name: "SwiftTUI", package: "swift-tui"),
            ]
        ),
        .testTarget(
            name: "ModelChatCoreTests",
            dependencies: ["ModelChatCore", "ModelTransport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
