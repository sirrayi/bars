import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusItemExtraUsageMetricTests {
    @Test
    func `menu bar extra usage preference preserves claude currency display`() {
        let (store, controller) = self.makeController(
            suiteName: "StatusItemExtraUsageMetricTests-claude-spend-text",
            provider: .claude)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 88.8,
                limit: 200,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        #expect(displayText == "$88.80")
    }

    private func makeController(
        suiteName: String,
        provider: UsageProvider,
        displayMode: MenuBarDisplayMode = .percent,
        resetTimesShowAbsolute: Bool = false) -> (UsageStore, StatusItemController)
    {
        let settings = testSettingsStore(suiteName: suiteName)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = provider.instanceID
        settings.menuBarDisplayMode = displayMode
        settings.resetTimesShowAbsolute = resetTimesShowAbsolute
        settings.usageBarsShowUsed = true
        settings.setMenuBarMetricPreference(.extraUsage, for: provider)

        let registry = ProviderRegistry.shared
        if let metadata = registry.metadata[provider] {
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: true)
        }

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (store, controller)
    }
}
