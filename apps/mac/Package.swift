// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EmojiSearch",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.19.2"),
    ],
    targets: [
        .executableTarget(
            name: "EmojiSearch",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/EmojiSearch",
            resources: [.copy("Resources/logo.png")],
        ),
    ],
    swiftLanguageVersions: [.v5]
)
