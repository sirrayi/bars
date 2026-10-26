import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreCLIUsageCacheTests {
    @Test
    func `opted in store caches default account providers and withdraws the file when off`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreCLIUsageCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        let store = Self.makeStore(shareUsage: true, cacheURL: url, providers: [.claude, .opencode])
        store._setSnapshotForTesting(Self.usage(), provider: .claude)
        store._setSnapshotForTesting(Self.usage(), provider: .opencode)

        // A selected token account (Claude) is skipped; the default OpenCode account is published.
        store.settings.addTokenAccount(provider: .claude, label: "Work", token: "Bearer sk-ant-oat-work-token")
        try await Self.persist(store)
        #expect(try #require(CLIUsageCache.load(from: url)).entries.map(\.provider) == ["opencode"])

        // A newly ineligible account must withdraw previously published usage.
        store.tokenAccountLiveStateProviders.insert(.opencode)
        try await Self.persist(store)
        #expect(try #require(CLIUsageCache.load(from: url)).entries.isEmpty)

        store.settings.updateConfig(reason: "test", affectsBackgroundWork: false) { $0.shareUsageWithCLI = false }
        try await Self.persist(store)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func `previous account snapshots are not republished under default settings`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        let store = Self.makeStore(shareUsage: true, cacheURL: url, providers: [.claude, .opencode])
        store._setSnapshotForTesting(Self.usage(), provider: .claude)
        store._setSnapshotForTesting(Self.usage(), provider: .opencode)
        store.tokenAccountLiveStateProviders.insert(.claude)
        store.tokenAccountLiveStateProviders.insert(.opencode)

        try await Self.persist(store)

        #expect(try #require(CLIUsageCache.load(from: url)).entries.isEmpty)
    }

    private static func persist(_ store: UsageStore) async throws {
        store.persistCLIUsageCache()
        await store.cliUsageCachePersistTask?.value
    }

    private static func makeStore(shareUsage: Bool, cacheURL: URL, providers: Set<UsageProvider>) -> UsageStore {
        var config = testConfigWithAllProvidersDisabled()
        config.shareUsageWithCLI = shareUsage
        let settings = testSettingsStore(
            suiteName: "UsageStoreCLIUsageCacheTests",
            userDefaults: InMemoryUserDefaults(),
            config: config)
        enableTestProviders(providers, settings: settings)
        return UsageStore(
            browserDetection: BrowserDetection(homeDirectory: "/synthetic", fileExists: { _ in false }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            cliUsageCacheURL: cacheURL)
    }

    private static func usage() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }
}
