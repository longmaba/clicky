// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClickyCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ClickyCore", targets: ["ClickyCore"])],
    targets: [
        .target(name: "CClickyAudio", publicHeadersPath: "include"),
        .target(name: "ClickyCore", dependencies: ["CClickyAudio"]),
        .testTarget(name: "ClickyCoreTests", dependencies: ["ClickyCore", "CClickyAudio"])
    ]
)
