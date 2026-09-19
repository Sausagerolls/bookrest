// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BookrestKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ABSClient", targets: ["ABSClient"]),
        .library(name: "BookrestCore", targets: ["BookrestCore"]),
    ],
    targets: [
        .target(
            name: "ABSClient",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "BookrestCore",
            dependencies: ["ABSClient"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ABSClientTests",
            dependencies: ["ABSClient"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BookrestCoreTests",
            dependencies: ["BookrestCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
