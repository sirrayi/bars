import AppKit
import BarsCore
import Foundation
import Testing
@testable import Bars

/// Regression coverage for battery drain caused by fallback-provider animation.
/// See GitHub issues #269, #139.
@MainActor
@Suite(.serialized)
struct BatteryDrainDiagnosticTests {
    private func ensureAppKitInitialized() {
        _ = NSApplication.shared
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        // Use the real system status bar in tests. Creating standalone NSStatusBar instances
        // has caused AppKit teardown crashes under swiftpm-testing-helper.
        .system
    }

    @Test
    func `Fallback provider should not animate when all providers are disabled`() {
        self.ensureAppKitInitialized()

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-AllDisabled"))

        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            if let meta = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: meta, enabled: false)
            }
        }

        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(
            controller.needsMenuBarIconAnimation() == false,
            "Should not animate when only fallback provider is visible")
        #expect(
            controller.animationDriver == nil,
            "Animation driver should not start for fallback provider")
    }

    @Test
    func `Enabled provider with data should not animate`() {
        self.ensureAppKitInitialized()

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-HasData"))

        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude

        let registry = ProviderRegistry.shared
        if let meta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: meta, enabled: true)
        }

        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(
            controller.needsMenuBarIconAnimation() == false,
            "Should not animate when provider has data")
        #expect(
            controller.animationDriver == nil,
            "Animation driver should be nil when data is present")
    }

    @Test
    func `Enabled provider without data should animate`() {
        self.ensureAppKitInitialized()

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-NoData"))

        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let registry = ProviderRegistry.shared
        if let meta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: meta, enabled: true)
        }

        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(
            controller.needsMenuBarIconAnimation() == true,
            "Should animate when enabled provider has no data")
    }

    @Test
    func `Enabled provider with error should not animate`() {
        self.ensureAppKitInitialized()

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-ErrorStops"))

        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let registry = ProviderRegistry.shared
        if let meta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: meta, enabled: true)
        }

        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setErrorForTesting("simulated provider timeout", provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        #expect(store.isStale(provider: .claude) == true)
        #expect(
            controller.needsMenuBarIconAnimation() == false,
            "Should not animate when provider has recorded an error")
        #expect(controller.animationDriver == nil)
    }
}
