import BarsCore
import Foundation
import Testing
@testable import Bars

@MainActor
struct UsageStoreTokenRefreshCadenceTests {
    @Test(arguments: [
        (RefreshFrequency.oneMinute, 900.0),
        (.twoMinutes, 900.0),
        (.fiveMinutes, 900.0),
        (.fifteenMinutes, 900.0),
        (.thirtyMinutes, 1800.0),
    ])
    func `fixed refresh frequencies derive a widget-safe token TTL`(
        frequency: RefreshFrequency,
        expectedSeconds: TimeInterval)
    {
        #expect(UsageStore.tokenFetchTTL(for: frequency) == expectedSeconds)
    }

    @Test(arguments: [RefreshFrequency.adaptive, .adaptiveAgentAware])
    func `adaptive refresh frequencies honor the fifteen minute token floor`(frequency: RefreshFrequency) {
        #expect(UsageStore.tokenFetchTTL(for: frequency) == TimeInterval(15 * 60))
    }

    @Test
    func `manual refresh disables the automatic token cadence`() {
        #expect(UsageStore.tokenFetchTTL(for: .manual) == nil)
    }

    @Test(arguments: [
        (RefreshFrequency.oneMinute, 1800.0),
        (.fiveMinutes, 1800.0),
        (.fifteenMinutes, 1800.0),
        (.thirtyMinutes, 1800.0),
    ])
    func `global low power mode clamps automatic token scans to thirty minutes`(
        frequency: RefreshFrequency,
        expectedSeconds: TimeInterval)
    {
        #expect(UsageStore.tokenFetchTTL(
            for: frequency,
            lowPowerModeEnabled: true) == expectedSeconds)
    }

    @Test
    func `global low power mode preserves manual token refresh`() {
        #expect(UsageStore.tokenFetchTTL(
            for: .manual,
            lowPowerModeEnabled: true) == nil)
    }

    @Test(arguments: [RefreshFrequency.oneMinute, .twoMinutes, .fiveMinutes])
    func `fast provider refreshes cannot rescan local cost within fifteen minutes`(
        frequency: RefreshFrequency) async throws
    {
        let settings = testSettingsStore(suiteName: "UsageStoreTokenRefreshCadenceTests-\(frequency.rawValue)")
        settings.refreshFrequency = frequency
        settings.costUsageEnabled = true
        settings.providerDetectionCompleted = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let now = Date()
        store._setTokenSnapshotForTesting(Self.tokenSnapshot(updatedAt: now), provider: .claude)
        store.lastTokenFetchScope[.claude] = store.tokenSnapshotScopeSignature(for: .claude)
        var scanCount = 0
        store._test_tokenUsageRefreshOverride = { _, _ in scanCount += 1 }

        store.lastTokenFetchAt[.claude] = now.addingTimeInterval(-14 * 60)
        await store.refreshTokenUsage(.claude, force: false)
        #expect(scanCount == 0)

        store.lastTokenFetchAt[.claude] = now.addingTimeInterval(-15 * 60 - 1)
        await store.refreshTokenUsage(.claude, force: false)
        #expect(scanCount == 1)
    }

    private static func tokenSnapshot(updatedAt: Date) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 1,
            sessionCostUSD: 0.01,
            last30DaysTokens: 1,
            last30DaysCostUSD: 0.01,
            daily: [],
            updatedAt: updatedAt)
    }
}
