// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReTiCAPush",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReTiCAPushCore", targets: ["ReTiCAPushCore"]),
        .library(name: "ReTiCAPush", targets: ["ReTiCAPush"]),
        .library(name: "ReTiCAPushExtension", targets: ["ReTiCAPushExtension"]),
    ],
    dependencies: [
        .package(path: "../ReTiCA"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.15.0"),
    ],
    targets: [
        // Pure pieces plus the HTTP client. No TCA, so the service extension can link it.
        .target(
            name: "ReTiCAPushCore",
            dependencies: [
                .product(name: "ReTiCA", package: "ReTiCA"),
                .product(name: "ReTiCAKeychain", package: "ReTiCA"),
            ]
        ),
        // The TCA feature the host app scopes in.
        .target(
            name: "ReTiCAPush",
            dependencies: [
                "ReTiCAPushCore",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        // What the Notification Service Extension links: stash, prove, return.
        .target(
            name: "ReTiCAPushExtension",
            dependencies: ["ReTiCAPushCore"]
        ),
        .testTarget(
            name: "ReTiCAPushCoreTests",
            dependencies: [
                "ReTiCAPushCore",
                .product(name: "ReTiCATransport", package: "ReTiCA"),
                .product(name: "ReTiCANode", package: "ReTiCA"),
                .product(name: "ReTiCAInterfaces", package: "ReTiCA"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ReTiCAPushTests",
            dependencies: [
                "ReTiCAPush",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ReTiCAPushExtensionTests",
            dependencies: [
                "ReTiCAPushExtension",
                .product(name: "ReTiCAKeychain", package: "ReTiCA"),
                // Tests only, for `LockIsolated`. The extension target itself stays TCA-free.
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
