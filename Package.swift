// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaPanel",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "QuotaPanel",
            path: "Sources/QuotaPanel"
        )
    ]
)
