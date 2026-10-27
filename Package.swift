// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Bookworm",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Bookworm", targets: ["Bookworm"])
    ],
    dependencies: [
        // Only third-party dep. Ships as a binary XCFramework via SPM;
        // required for auto-update because the ad-hoc-signed .app can't
        // ride Apple's Developer ID / MAS update path.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "Bookworm",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Bookworm",
            resources: [
                .copy("Resources/Color_orb.usdz")
            ],
            swiftSettings: [
                // Keep Swift 5 semantics — Swift 6 strict-concurrency surfaces
                // a bunch of pre-existing actor/Sendable issues that would
                // sprawl this change beyond its scope. The toolchain stays at
                // 6.0 only so we can declare the macOS 15 platform.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
