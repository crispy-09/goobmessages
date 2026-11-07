// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GMessagesMac",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.27.0"),
    ],
    targets: [
        .executableTarget(
            name: "GMessagesMac",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            path: "Sources/GMessagesMac"
        ),
        .testTarget(
            name: "GMessagesMacTests",
            dependencies: ["GMessagesMac"],
            path: "Tests/GMessagesMacTests"
        ),
    ]
)
