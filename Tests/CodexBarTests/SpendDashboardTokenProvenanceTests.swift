import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SpendDashboardTokenProvenanceTests {
    @Test
    func `token publication counter remains monotonic across clear and identical republish`() {
        let (_, store) = Self.makeStore(provider: .claude)
        let snapshot = Self.tokenSnapshot(cost: 9)
        store._setTokenSnapshotForTesting(snapshot, provider: .claude)
        let firstRevision = store.tokenSnapshotPublicationRevision(for: .claude)

        store._setTokenSnapshotForTesting(nil, provider: .claude)
        store._setTokenSnapshotForTesting(snapshot, provider: .claude)

        #expect(store.tokenSnapshotPublicationRevision(for: .claude) > firstRevision)
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .claude)?.snapshot == snapshot)
    }

    private static let fixtureNow = Date(timeIntervalSince1970: 1_784_179_200)
    private nonisolated static let monthBoundaryDates = [
        Date(timeIntervalSince1970: 1_785_542_399), // 2026-07-31 23:59:59 UTC
        Date(timeIntervalSince1970: 1_785_542_400), // 2026-08-01 00:00:00 UTC
    ]

    private static func dashboardController(
        settings: SettingsStore,
        store: UsageStore,
        now: Date) -> SpendDashboardController
    {
        SpendDashboardController(
            userDefaults: settings.userDefaults,
            requestBuilder: { mode in
                await SpendDashboardSource.makeRequest(
                    settings: settings,
                    store: store,
                    mode: mode,
                    now: now)
            },
            nowProvider: { now })
    }

    private static func tokenSnapshot(cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: cost,
            last30DaysTokens: 10,
            last30DaysCostUSD: cost,
            currencyCode: "USD",
            daily: [CostUsageDailyReport.Entry(
                date: "2026-07-16",
                inputTokens: 4,
                outputTokens: 6,
                totalTokens: 10,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Date(timeIntervalSince1970: 1_784_203_200))
    }

    private static func emptyTokenSnapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 0,
            last30DaysCostUSD: 0,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
    }

    private static func mistralOutcomeWithoutCostProjection() -> ProviderFetchOutcome {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
                credits: nil,
                sourceLabel: "fixture",
                strategyID: "fixture",
                strategyKind: .apiToken)),
            attempts: [])
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for provenance state")
    }

    private static func makeStore(provider: UsageProvider) -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(suiteName: "SpendDashboardTokenProvenanceTests-\(provider.rawValue)")
        settings.costUsageEnabled = true
        for candidate in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[candidate] else { continue }
            settings.setProviderEnabled(provider: candidate, metadata: metadata, enabled: candidate == provider)
        }
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return (settings, store)
    }
}

private actor SpendDashboardProvenanceGate {
    private var callCount = 0
    private var firstReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func enter() async -> Int {
        self.callCount += 1
        let call = self.callCount
        let ready = self.callWaiters.filter { self.callCount >= $0.count }
        self.callWaiters.removeAll { self.callCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        if call == 1, !self.firstReleased {
            await withCheckedContinuation { continuation in
                self.releaseContinuations.append(continuation)
            }
        }
        return call
    }

    func waitForCalls(_ count: Int) async {
        if self.callCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            self.callWaiters.append((count, continuation))
        }
    }

    func releaseFirst() {
        self.firstReleased = true
        let continuations = self.releaseContinuations
        self.releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}
