import BarsCore
import Foundation
import Testing
@testable import Bars

/// Covers `normalRefreshIntervalForHeuristics()` and every consumer that previously read
/// `RefreshFrequency.seconds` directly. That property is nil for both `.manual` and `.adaptive`,
/// so without the helper the interval-derived heuristics (reset-boundary refresh,
/// persistent-CLI-session idle windows) silently degrade to manual behavior the
/// moment a user picks adaptive. Each consumer has a test here that goes red if its call site
/// is reverted to `.seconds`.
@MainActor
struct AdaptiveRefreshHeuristicsTests {
    @Test
    func `heuristics fixture seeds disabled providers`() throws {
        let store = Self.makeStore(suite: "heuristics-fixture-state", frequency: .adaptive)
        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases where metadata[provider] != nil {
            let entry = try #require(store.settings.configSnapshot.providerConfig(for: provider.instanceID))
            #expect(entry.enabled == false)
        }
        #expect(store.settings.enabledProvidersOrdered(metadataByProvider: metadata).isEmpty)
        #expect(store.settings.refreshFrequency == .adaptive)
        #expect(store.settings.providerDetectionCompleted)
        #expect(store.settings.backgroundWorkLowPowerModePreference == .off)
        #expect(store.completedRefreshCountForTesting == 0)
    }

    @Test
    func `reset boundary fixture enables only stubbed claude`() throws {
        let store = Self.makeStoreWithStubbedClaude(suite: "heuristics-stub-fixture-state", frequency: .manual)
        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases where metadata[provider] != nil {
            let entry = try #require(store.settings.configSnapshot.providerConfig(for: provider.instanceID))
            #expect(entry.enabled == (provider == .claude))
        }
        #expect(store.settings.enabledProvidersOrdered(metadataByProvider: metadata) == [.claude])
        #expect(store.completedRefreshCountForTesting == 0)
    }

    @Test
    func `manual keeps the heuristics interval nil`() {
        let store = Self.makeStore(suite: "heuristics-manual-nil", frequency: .manual)
        #expect(store.normalRefreshIntervalForHeuristics() == nil)
    }

    @Test(arguments: [
        (RefreshFrequency.oneMinute, 60.0),
        (.twoMinutes, 120.0),
        (.fiveMinutes, 300.0),
        (.fifteenMinutes, 900.0),
        (.thirtyMinutes, 1800.0)
    ])
    func `fixed frequencies pass their configured seconds through`(
        frequency: RefreshFrequency,
        expectedSeconds: TimeInterval)
    {
        let store = Self.makeStore(suite: "heuristics-fixed-\(frequency.rawValue)", frequency: frequency)
        #expect(store.normalRefreshIntervalForHeuristics() == expectedSeconds)
    }

    @Test
    func `global low power mode clamps fixed and interactive adaptive heuristics`() {
        let fixedStore = Self.makeStore(suite: "heuristics-low-power-fixed", frequency: .oneMinute)
        fixedStore.settings.backgroundWorkLowPowerModePreference = .on
        #expect(fixedStore.normalRefreshIntervalForHeuristics() == 1800.0)

        let adaptiveStore = Self.makeStore(suite: "heuristics-low-power-adaptive", frequency: .adaptive)
        adaptiveStore.settings.backgroundWorkLowPowerModePreference = .on
        adaptiveStore.noteMenuOpened()
        #expect(adaptiveStore.normalRefreshIntervalForHeuristics() == 1800.0)

        let manualStore = Self.makeStore(suite: "heuristics-low-power-manual", frequency: .manual)
        manualStore.settings.backgroundWorkLowPowerModePreference = .on
        #expect(manualStore.normalRefreshIntervalForHeuristics() == nil)
    }

    @Test
    func `adaptive resolves to the live adaptive decision delay`() {
        let store = Self.makeStore(suite: "heuristics-adaptive-live", frequency: .adaptive)

        // No recorded menu open: the decision is longIdle, or constrained on a low-power/hot
        // machine — both are 30 minutes, so this assertion is environment-independent.
        #expect(store.normalRefreshIntervalForHeuristics() == 1800.0)

        store.noteMenuOpened()
        let expected = TimeInterval(UsageStore.adaptiveRefreshDecision(
            now: Date(),
            lastMenuOpenAt: store.lastMenuOpenAt,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState).delay.components.seconds)
        #expect(store.normalRefreshIntervalForHeuristics() == expected)
        if Self.machineIsUnconstrained {
            #expect(store.normalRefreshIntervalForHeuristics() == 120.0)
        }
    }

    @Test
    func `adaptive cadence schedules a reset-boundary refresh through the refresh pipeline`() async {
        let store = Self.makeStoreWithStubbedClaude(suite: "heuristics-boundary-adaptive", frequency: .adaptive)

        // Goes through the real end-of-refresh scheduling call, which must feed the adaptive
        // interval (30 min here — no menu open) rather than the nil `RefreshFrequency.seconds`.
        await store.refresh()
        defer { store.cancelResetBoundaryRefresh() }

        #expect(store.scheduledResetBoundaryRefreshAt != nil)
    }

    @Test
    func `manual cadence still never schedules a reset-boundary refresh through the refresh pipeline`() async {
        let store = Self.makeStoreWithStubbedClaude(suite: "heuristics-boundary-manual", frequency: .manual)

        await store.refresh()
        defer { store.cancelResetBoundaryRefresh() }

        #expect(store.scheduledResetBoundaryRefreshAt == nil)
    }

    @Test
    func `registry nominal interval maps adaptive to the policy nominal and keeps manual nil`() {
        #expect(ProviderRegistry.nominalRefreshInterval(for: .adaptive)
            == AdaptiveRefreshPolicy.nominalIntervalForHeuristics)
        #expect(ProviderRegistry.nominalRefreshInterval(for: .manual) == nil)
        #expect(ProviderRegistry.nominalRefreshInterval(for: .thirtyMinutes) == 1800.0)
    }

    @Test
    func `provider specs give adaptive a nominal cli session idle window instead of the floor`() {
        let adaptiveStore = Self.makeStore(suite: "heuristics-spec-adaptive", frequency: .adaptive)
        let manualStore = Self.makeStore(suite: "heuristics-spec-manual", frequency: .manual)

        // Registry specs have no UsageStore to ask, so adaptive maps to the policy's nominal
        // 300s steady-state interval: max(180, 300 + 60) = 360.
        let adaptiveWindow = adaptiveStore.providerSpecs[.claude]?
            .makeFetchContext().persistentCLISessionIdleWindow
        let manualWindow = manualStore.providerSpecs[.claude]?
            .makeFetchContext().persistentCLISessionIdleWindow
        #expect(adaptiveWindow == 360)
        #expect(manualWindow == 180)
    }

    @Test
    func `account-scoped fetch contexts derive the idle window from the live adaptive interval`() {
        let adaptiveStore = Self.makeStore(suite: "heuristics-account-adaptive", frequency: .adaptive)
        let manualStore = Self.makeStore(suite: "heuristics-account-manual", frequency: .manual)

        // Unlike registry specs, this path runs inside UsageStore, so adaptive uses the live
        // decision: 1800s with no menu open, giving max(180, 1800 + 60) = 1860.
        let adaptiveWindow = adaptiveStore
            .makeFetchContext(provider: .claude, override: nil).persistentCLISessionIdleWindow
        let manualWindow = manualStore
            .makeFetchContext(provider: .claude, override: nil).persistentCLISessionIdleWindow
        #expect(adaptiveWindow == 1860)
        #expect(manualWindow == 180)
    }

    private static var machineIsUnconstrained: Bool {
        let thermalState = ProcessInfo.processInfo.thermalState
        return !ProcessInfo.processInfo.isLowPowerModeEnabled
            && (thermalState == .nominal || thermalState == .fair)
    }

    private static func makeStore(suite: String, frequency: RefreshFrequency) -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "AdaptiveRefreshHeuristicsTests-\(suite)",
            config: testConfigWithAllProvidersDisabled())
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = frequency
        return UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    /// The reset-boundary pipeline tests need `refresh()` to complete with a snapshot still in
    /// place, and `clearProviderRuntimeState` wipes snapshots of disabled providers. So
    /// Claude stays enabled but its fetch is stubbed to return a canned snapshot whose primary
    /// window resets 10 minutes out — inside a 30-minute normal-refresh window, outside nothing.
    private static func makeStoreWithStubbedClaude(suite: String, frequency: RefreshFrequency) -> UsageStore {
        let store = Self.makeStore(suite: suite, frequency: frequency)
        let metadata = ProviderRegistry.shared.metadata[.claude]!
        store.settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        store.providerSpecs[.claude] = .stubbed(store.providerSpecs[.claude]!) {
            Self.snapshot(updatedAt: Date(), primaryResetsAt: Date().addingTimeInterval(10 * 60))
        }
        return store
    }

    private nonisolated static let stubbedClaudeEmail = "adaptive-heuristics@example.com"

    private nonisolated static func snapshot(updatedAt: Date, primaryResetsAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: 300,
                resetsAt: primaryResetsAt,
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: self.stubbedClaudeEmail,
                accountOrganization: nil,
                loginMethod: "Pro"))
    }
}
