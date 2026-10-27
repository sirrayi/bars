// swift-tools-version: 6.2
import Foundation
import PackageDescription

let sweetCookieKitPath = "../SweetCookieKit"
let useLocalSweetCookieKit =
    ProcessInfo.processInfo.environment["BARS_USE_LOCAL_SWEETCOOKIEKIT"] == "1"
let sweetCookieKitDependency: Package.Dependency =
    useLocalSweetCookieKit && FileManager.default.fileExists(atPath: sweetCookieKitPath)
    ? .package(path: sweetCookieKitPath)
    : .package(url: "https://github.com/steipete/SweetCookieKit", from: "0.5.9")

let package = Package(
    name: "bars",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: {
        var products: [Product] = [
            .library(name: "BarsCore", targets: ["BarsCore"]),
            .executable(name: "BarsCLI", targets: ["BarsCLI"]),
            // Offline adaptive-refresh replay harness. Keep the supporting library package-internal.
            .executable(name: "AdaptiveReplayCLI", targets: ["AdaptiveReplayCLI"]),
        ]

        #if os(macOS)
        products.append(contentsOf: [
            .executable(name: "bars", targets: ["Bars"]),
            .executable(name: "BarsClaudeWatchdog", targets: ["BarsClaudeWatchdog"]),
            .executable(name: "BarsWidget", targets: ["BarsWidget"]),
            .executable(name: "BarsClaudeWebProbe", targets: ["BarsClaudeWebProbe"]),
        ])
        #endif

        return products
    }(),
    dependencies: [
        .package(url: "https://github.com/steipete/Commander", from: "0.2.4"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
        .package(url: "https://github.com/apple/swift-log", from: "1.15.1"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.1.0"),
        .package(url: "https://github.com/zats/Vortex", revision: "ef5392088d4aeb255c4eee83157dbdafcd31bf07"),
        sweetCookieKitDependency,
    ],
    targets: {
        var targets: [Target] = [
            .target(
                name: "BarsCore",
                dependencies: [
                    .product(name: "Crypto", package: "swift-crypto"),
                    .product(name: "Logging", package: "swift-log"),
                    .product(name: "SweetCookieKit", package: "SweetCookieKit"),
                ],
                resources: [
                    .process("Resources"),
                ],
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .executableTarget(
                name: "BarsCLI",
                dependencies: [
                    "BarsCore",
                    .product(name: "Commander", package: "Commander"),
                    .product(name: "Crypto", package: "swift-crypto"),
                ],
                path: "Sources/BarsCLI",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            // Sole owner of the adaptive refresh decision table. Package-internal so the app and
            // offline replay tool share behavior without publishing another library product.
            .target(
                name: "AdaptiveRefreshCore",
                dependencies: [],
                path: "Sources/AdaptiveRefreshCore",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            // Offline adaptive-refresh replay harness: pure Foundation,
            // no Bars/BarsCore dependency, so it builds anywhere BarsCore does.
            .target(
                name: "AdaptiveReplayKit",
                dependencies: ["AdaptiveRefreshCore"],
                path: "Sources/AdaptiveReplayKit",
                exclude: ["README.md"],
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .executableTarget(
                name: "AdaptiveReplayCLI",
                dependencies: ["AdaptiveReplayKit"],
                path: "Sources/AdaptiveReplayCLI",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .testTarget(
                name: "AdaptiveReplayCLITests",
                dependencies: ["AdaptiveReplayCLI", "AdaptiveReplayKit"],
                path: "Tests/AdaptiveReplayCLITests",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                    .enableExperimentalFeature("SwiftTesting"),
                ]),
            .testTarget(
                name: "AdaptiveReplayKitTests",
                dependencies: ["AdaptiveRefreshCore", "AdaptiveReplayKit"],
                path: "Tests/AdaptiveReplayKitTests",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                    .enableExperimentalFeature("SwiftTesting"),
                ]),
        ]

        #if os(macOS)
        targets.append(contentsOf: [
            .executableTarget(
                name: "BarsClaudeWatchdog",
                dependencies: [],
                path: "Sources/BarsClaudeWatchdog",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .executableTarget(
                name: "Bars",
                dependencies: [
                    .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                    .product(name: "Vortex", package: "Vortex"),
                    "AdaptiveRefreshCore",
                    "BarsCore",
                ],
                path: "Sources/Bars",
                resources: [
                    .process("Resources"),
                ],
                swiftSettings: [
                    // Opt into Swift 6 strict concurrency (approachable migration path).
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .executableTarget(
                name: "BarsWidget",
                dependencies: ["BarsCore"],
                path: "Sources/BarsWidget",
                resources: [
                    .process("Resources"),
                ],
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .executableTarget(
                name: "BarsClaudeWebProbe",
                dependencies: ["BarsCore"],
                path: "Sources/BarsClaudeWebProbe",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
        ])

        targets.append(.testTarget(
            name: "BarsTests",
            dependencies: [
                "Bars", "BarsCore", "BarsCLI", "BarsWidget",
            ],
            path: "Tests",
            exclude: [
                "AdaptiveReplayCLITests",
                "AdaptiveReplayKitTests",
            ],
            resources: [
                .copy("BarsTests/Fixtures"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableExperimentalFeature("SwiftTesting"),
            ],
            linkerSettings: [
                // XCTest's executable is three directories below its sibling framework products.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."]),
            ]))
        #endif

        return targets
    }())
