// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "QuotaBar", path: "Sources/QuotaBar"),
        .testTarget(name: "QuotaBarTests", dependencies: ["QuotaBar"], path: "Tests/QuotaBarTests"),
    ],
    swiftLanguageModes: [.v5]
)
