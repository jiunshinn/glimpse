// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glimpse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Glimpse",
            path: "Sources/Glimpse"
        ),
    ],
    swiftLanguageModes: [.v5]
)
