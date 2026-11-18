// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DolaLite",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DolaLite", path: "Sources/DolaLite"),
        .testTarget(name: "DolaLiteTests", dependencies: ["DolaLite"], path: "Tests/DolaLiteTests"),
    ]
)
