import BarsCore
import Foundation
import Testing
@testable import Bars

@MainActor
struct ClaudeCombinedMetricHighestUsageTests {
    @Test
    func `combined claude metric stays eligible when only one lane is exhausted`() {
        let store = self.makeStore(
            suiteName: "ClaudeCombinedMetricHighestUsageTests-claude-one-exhausted")

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 30,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .claude)

        // Claude's session lane is exhausted but the weekly lane still has room, so the combined
        // metric must keep Claude eligible instead of dropping it from ranking.
        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 100)
    }

    @Test
    func `combined claude metric is excluded when both lanes are exhausted`() {
        let store = self.makeStore(
            suiteName: "ClaudeCombinedMetricHighestUsageTests-claude-both-exhausted")

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .claude)

        // Both Claude lanes are exhausted, so the combined metric must drop Claude from ranking.
        let highest = store.providerWithHighestUsage()
        #expect(highest == nil)
    }

    @Test
    func `combined claude metric excludes an exhausted weekly-only account with a synthetic placeholder`() {
        let store = self.makeStore(
            suiteName: "ClaudeCombinedMetricHighestUsageTests-claude-placeholder-exhausted")

        // Claude web weekly-only account: a synthetic 0% session placeholder plus an exhausted weekly lane.
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil,
                    isSyntheticPlaceholder: true),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .claude)

        // The placeholder is not a real lane, so the only real Claude lane (weekly) is fully exhausted —
        // Claude must be excluded from ranking, not kept eligible by the phantom 0% session.
        let highest = store.providerWithHighestUsage()
        #expect(highest == nil)
    }

    @Test
    func `combined claude metric excludes an exhausted spend-limit-only account`() {
        let store = self.makeStore(
            suiteName: "ClaudeCombinedMetricHighestUsageTests-claude-spend-limit-exhausted")

        // Claude spend-limit-only account: exhausted providerCost, no secondary/tertiary, and an
        // explicitly marked 0% 5h placeholder primary. The metric resolves to the exhausted spend-limit window.
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil,
                    isSyntheticPlaceholder: true),
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 100,
                    limit: 100,
                    currencyCode: "USD",
                    period: "Spend limit",
                    updatedAt: Date()),
                updatedAt: Date()),
            provider: .claude)

        // The spend limit is exhausted and there are no real lanes, so Claude must be excluded from
        // ranking (the marked 0% placeholder must not keep it eligible).
        let highest = store.providerWithHighestUsage()
        #expect(highest == nil)
    }

    private func makeStore(suiteName: String) -> UsageStore {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: suiteName))
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .claude)

        if let claudeMeta = ProviderRegistry.shared.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        return UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
    }
}
