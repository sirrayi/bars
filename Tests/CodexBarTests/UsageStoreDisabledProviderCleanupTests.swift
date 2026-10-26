import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreDisabledProviderCleanupTests {
    @Test
    func `disabled cleanup rejects stale status success after re-enable`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-status-success")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = true
        try Self.setOnlyProvider(.opencode, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        store._test_providerStatusFetchOverride = { _ in
            await gate.suspend()
            return ProviderStatus(indicator: .major, description: "stale", updatedAt: Date())
        }

        let staleTask = Task { await store.refreshProviderStatus(.opencode) }
        await gate.waitUntilStarted()
        try Self.setProvider(.opencode, enabled: false, settings: settings)
        try Self.setProvider(.opencode, enabled: true, settings: settings)
        await gate.resume()
        await staleTask.value

        #expect(store.statuses[.opencode] == nil)

        store._test_providerStatusFetchOverride = { _ in
            ProviderStatus(indicator: .none, description: "fresh", updatedAt: Date())
        }
        await store.refreshProviderStatus(.opencode)
        #expect(store.statuses[.opencode]?.description == "fresh")
    }

    @Test
    func `disabled cleanup rejects stale status failure after re-enable`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-status-failure")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = true
        try Self.setOnlyProvider(.opencode, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        store._test_providerStatusFetchOverride = { _ in
            await gate.suspend()
            throw CleanupTestError.failed
        }

        let staleTask = Task { await store.refreshProviderStatus(.opencode) }
        await gate.waitUntilStarted()
        try Self.setProvider(.opencode, enabled: false, settings: settings)
        store.clearDisabledProviderState(enabledProviders: [])
        try Self.setProvider(.opencode, enabled: true, settings: settings)
        await gate.resume()
        await staleTask.value

        #expect(store.statuses[.opencode] == nil)
    }

    @Test
    func `disabled cleanup rejects stale token result after re-enable`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-token-race")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        try Self.setOnlyProvider(.claude, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        var loadCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, historyDays in
            loadCount += 1
            if loadCount == 1 {
                await gate.suspend()
                return Self.tokenSnapshot(tokens: 710, historyDays: historyDays)
            }
            return Self.tokenSnapshot(tokens: 190, historyDays: historyDays)
        }

        let staleTask = Task { await store.refreshTokenUsage(.claude, force: true) }
        await gate.waitUntilStarted()
        try Self.setProvider(.claude, enabled: false, settings: settings)
        store.clearDisabledProviderState(enabledProviders: [])
        try Self.setProvider(.claude, enabled: true, settings: settings)
        await gate.resume()
        await staleTask.value
        for _ in 0..<100 where store.tokenSnapshot(for: .claude) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.tokenSnapshot(for: .claude)?.sessionTokens == 190)
        #expect(loadCount == 2)
    }

    @Test
    func `disabled cleanup replaces stale token failure with fresh retry`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-token-failure")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        try Self.setOnlyProvider(.claude, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        var loadCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, historyDays in
            loadCount += 1
            if loadCount == 1 {
                await gate.suspend()
                throw CleanupTestError.failed
            }
            return Self.tokenSnapshot(tokens: 190, historyDays: historyDays)
        }

        let staleTask = Task { await store.refreshTokenUsage(.claude, force: true) }
        await gate.waitUntilStarted()
        try Self.setProvider(.claude, enabled: false, settings: settings)
        store.clearDisabledProviderState(enabledProviders: [])
        try Self.setProvider(.claude, enabled: true, settings: settings)
        await gate.resume()
        await staleTask.value
        for _ in 0..<100 where store.tokenSnapshot(for: .claude) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.tokenSnapshot(for: .claude)?.sessionTokens == 190)
        #expect(store.tokenError(for: .claude) == nil)
        #expect(loadCount == 2)
    }

    @Test
    func `disabled token completion preserves retry through active sequence`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-token-sequence")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        try Self.setOnlyProvider(.claude, enabled: true, settings: settings)
        try Self.setProvider(.devin, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let claudeGate = CleanupAsyncGate()
        let devinGate = CleanupAsyncGate()
        var claudeLoads = 0
        var devinLoads = 0
        store._test_tokenUsageSnapshotLoaderOverride = { provider, _, _, historyDays in
            switch provider {
            case .claude:
                claudeLoads += 1
                if claudeLoads == 1 {
                    await claudeGate.suspend()
                    return Self.tokenSnapshot(tokens: 710, historyDays: historyDays)
                }
                return Self.tokenSnapshot(tokens: 190, historyDays: historyDays)
            case .devin:
                devinLoads += 1
                if devinLoads == 1 {
                    await devinGate.suspend()
                }
                return Self.tokenSnapshot(tokens: 50, historyDays: historyDays)
            default:
                return Self.tokenSnapshot(tokens: 1, historyDays: historyDays)
            }
        }

        store.scheduleTokenRefreshForTesting()
        let originalSequence = try #require(store.tokenRefreshSequenceTask)
        await claudeGate.waitUntilStarted()
        try Self.setProvider(.claude, enabled: false, settings: settings)
        store.clearDisabledProviderState(enabledProviders: [.devin])
        await claudeGate.resume()

        await devinGate.waitUntilStarted()
        try Self.setProvider(.claude, enabled: true, settings: settings)
        store.scheduleTokenRefreshForTesting()
        await devinGate.resume()
        await originalSequence.value
        await store.tokenRefreshSequenceTask?.value

        #expect(store.tokenSnapshot(for: .claude)?.sessionTokens == 190)
        #expect(claudeLoads == 2)
        #expect(devinLoads == 1)
        #expect(store.tokenRefreshSequenceTask == nil)
    }

    @Test
    func `token configuration change rejects stale result`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-token-scope")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 30
        try Self.setOnlyProvider(.claude, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        var loadCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, historyDays in
            loadCount += 1
            if loadCount == 1 {
                await gate.suspend()
                return Self.tokenSnapshot(tokens: 710, historyDays: historyDays)
            }
            return Self.tokenSnapshot(tokens: 190, historyDays: historyDays)
        }

        let staleTask = Task { await store.refreshTokenUsage(.claude, force: true) }
        await gate.waitUntilStarted()
        settings.costUsageHistoryDays = 7
        await gate.resume()
        await staleTask.value
        for _ in 0..<100 where store.tokenSnapshot(for: .claude) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.tokenSnapshot(for: .claude)?.sessionTokens == 190)
        #expect(loadCount == 2)
    }

    @Test
    func `disabled Claude cleanup clears swap runtime without touching settings`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-claude-swap")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.claudeSwapEnabled = true
        settings.claudeSwapExecutablePath = "/tmp/cswap-fixture"

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(provider: .opencode, metadata: #require(metadata[.opencode]), enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        store.claudeSwapAccountSnapshots = [
            ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "1"),
                provider: .claude,
                displayLabel: "account@example.com",
                isActive: false,
                snapshot: nil,
                error: "Token expired",
                sourceLabel: ClaudeSwapAccountProjection.sourceLabel),
        ]
        store.claudeSwapLastRefreshAt = Date()
        store.claudeSwapLastError = "stale"

        store.clearDisabledProviderState(enabledProviders: Set(store.enabledProvidersForDisplay()))

        #expect(store.claudeSwapAccountSnapshots.isEmpty)
        #expect(store.claudeSwapLastRefreshAt == nil)
        #expect(store.claudeSwapLastError == nil)
        #expect(settings.claudeSwapEnabled)
        #expect(settings.claudeSwapExecutablePath == "/tmp/cswap-fixture")
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        return settings
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func setOnlyProvider(
        _ provider: UsageProvider,
        enabled: Bool,
        settings: SettingsStore) throws
    {
        let metadata = ProviderRegistry.shared.metadata
        for candidate in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: candidate,
                metadata: #require(metadata[candidate]),
                enabled: candidate == provider && enabled)
        }
    }

    private static func setProvider(
        _ provider: UsageProvider,
        enabled: Bool,
        settings: SettingsStore) throws
    {
        try settings.setProviderEnabled(
            provider: provider,
            metadata: #require(ProviderRegistry.shared.metadata[provider]),
            enabled: enabled)
    }

    private static func usageSnapshot(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }

    private static func providerOutcome(snapshot: UsageSnapshot) -> ProviderFetchOutcome {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: snapshot,
                credits: nil,
                sourceLabel: "fixture",
                strategyID: "fixture",
                strategyKind: .cli)),
            attempts: [])
    }

    private static func tokenSnapshot(
        tokens: Int,
        historyDays: Int,
        updatedAt: Date = Date()) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: 1,
            last30DaysTokens: tokens,
            last30DaysCostUSD: 1,
            historyDays: historyDays,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-11",
                    inputTokens: tokens,
                    outputTokens: 0,
                    totalTokens: tokens,
                    costUSD: 1,
                    modelsUsed: [],
                    modelBreakdowns: nil),
            ],
            updatedAt: updatedAt)
    }
}

private enum CleanupTestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "fixture failure"
    }
}

private actor CleanupAsyncGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        self.started = true
        for waiter in self.startWaiters {
            waiter.resume()
        }
        self.startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            self.releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func resume() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}
