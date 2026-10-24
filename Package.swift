// swift-tools-version: 6.2
import Foundation
import PackageDescription

let sweetCookieKitPath = "../SweetCookieKit"
let useLocalSweetCookieKit =
    ProcessInfo.processInfo.environment["CODEXBAR_USE_LOCAL_SWEETCOOKIEKIT"] == "1"
let sweetCookieKitDependency: Package.Dependency =
    useLocalSweetCookieKit && FileManager.default.fileExists(atPath: sweetCookieKitPath)
    ? .package(path: sweetCookieKitPath)
    : .package(url: "https://github.com/steipete/SweetCookieKit", from: "0.5.9")

let package = Package(
    name: "CodexBar",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: {
        var products: [Product] = [
            .library(name: "CodexBarCore", targets: ["CodexBarCore"]),
            .executable(name: "CodexBarCLI", targets: ["CodexBarCLI"]),
            // Offline adaptive-refresh replay harness. Keep the supporting library package-internal.
            .executable(name: "AdaptiveReplayCLI", targets: ["AdaptiveReplayCLI"]),
        ]

        #if os(macOS)
        products.append(contentsOf: [
            .executable(name: "CodexBar", targets: ["CodexBar"]),
            .executable(name: "CodexBarClaudeWatchdog", targets: ["CodexBarClaudeWatchdog"]),
            .executable(name: "CodexBarWidget", targets: ["CodexBarWidget"]),
            .executable(name: "CodexBarClaudeWebProbe", targets: ["CodexBarClaudeWebProbe"]),
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
                name: "CQuickJS",
                path: "Sources/CQuickJS",
                exclude: ["README.md", "LICENSE"],
                publicHeadersPath: "include",
                cSettings: [
                    .define("_GNU_SOURCE"),
                ]),
            .target(
                name: "CodexBarCore",
                dependencies: [
                    "CQuickJS",
                    .product(name: "Crypto", package: "swift-crypto"),
                    .product(name: "Logging", package: "swift-log"),
                    .product(name: "SweetCookieKit", package: "SweetCookieKit"),
                ],
                resources: [
                    .process("Resources"),
                ],
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ],
                linkerSettings: [
                    .linkedFramework("JavaScriptCore", .when(platforms: [.macOS])),
                ]),
            .executableTarget(
                name: "CodexBarCLI",
                dependencies: [
                    "CodexBarCore",
                    .product(name: "Commander", package: "Commander"),
                    .product(name: "Crypto", package: "swift-crypto"),
                ],
                path: "Sources/CodexBarCLI",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            // Crash-test subprocess: tests SIGKILL it mid-save to prove the cost store's
            // save cycle is atomic. Not shipped; built only as a test dependency.
            .executableTarget(
                name: "CodexBarCostStoreCrashProbe",
                dependencies: ["CodexBarCore"],
                path: "Sources/CodexBarCostStoreCrashProbe",
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
            // no CodexBar/CodexBarCore dependency, so it builds anywhere CodexBarCore does.
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
            .testTarget(
                name: "CodexBarPluginTests",
                dependencies: ["CodexBarCore"],
                path: "TestsPlugin",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                    .enableExperimentalFeature("SwiftTesting"),
                ]),
            .testTarget(
                name: "CodexBarLinuxTests",
                dependencies: [
                    "CodexBarCore",
                    "CodexBarCLI",
                ],
                path: "TestsLinux",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                    .enableExperimentalFeature("SwiftTesting"),
                ]),
        ]

        #if os(macOS)
        targets.append(contentsOf: [
            .executableTarget(
                name: "CodexBarClaudeWatchdog",
                dependencies: [],
                path: "Sources/CodexBarClaudeWatchdog",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .executableTarget(
                name: "CodexBar",
                dependencies: [
                    .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                    .product(name: "Vortex", package: "Vortex"),
                    "AdaptiveRefreshCore",
                    "CodexBarCore",
                ],
                path: "Sources/CodexBar",
                resources: [
                    .process("Resources"),
                ],
                swiftSettings: [
                    // Opt into Swift 6 strict concurrency (approachable migration path).
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .executableTarget(
                name: "CodexBarWidget",
                dependencies: ["CodexBarCore"],
                path: "Sources/CodexBarWidget",
                resources: [
                    .process("Resources"),
                ],
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .executableTarget(
                name: "CodexBarClaudeWebProbe",
                dependencies: ["CodexBarCore"],
                path: "Sources/CodexBarClaudeWebProbe",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
        ])

        targets.append(.testTarget(
            name: "CodexBarTests",
            dependencies: [
                "CodexBar", "CodexBarCore", "CodexBarCLI", "CodexBarCostStoreCrashProbe", "CodexBarWidget",
            ],
            path: "Tests",
            exclude: [
                "AdaptiveReplayCLITests",
                "AdaptiveReplayKitTests",
                "CodexBarTests/ProviderPluginDetailsParityTests.swift",
                "CodexBarTests/ProviderPluginExtensionParityTests.swift",
                "CodexBarTests/ProviderPluginParityTests.swift",
                "CodexBarTests/ProviderPluginRuntimeTests.swift",
                "CodexBarTests/Sub2APIPluginGoldenTests.swift",
            ],
            resources: [
                .copy("CodexBarTests/Fixtures"),
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
