// swift-tools-version: 5.9
import PackageDescription
import Foundation

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let excluded = ["build", "dist"] + ["Packages", "scripts", "docs", "website", ".github", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "CONTRIBUTING.md", "Clicky.xcodeproj", "App/Info.plist"].filter {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
} + ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter {
    $0.hasSuffix(".mp4") || $0.hasSuffix(".webm")
}

let package = Package(
    name: "Clicky",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "Packages/ClickyCore")],
    targets: [
        .executableTarget(name: "Clicky", dependencies: [.product(name: "ClickyCore", package: "ClickyCore")], path: ".", exclude: excluded, sources: ["App"], resources: [.copy("Assets")])
    ]
)
