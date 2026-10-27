import AppKit
import BarsCore
import Testing
@testable import Bars

@MainActor
@Suite(.serialized)
struct StatusMenuNativeSectionSpacingTests {
    @Test
    func `usage history cost and storage stay together without adjacent separators`() throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        settings.providerStorageFootprintsEnabled = true
        self.enableOnly(.claude, settings: settings)

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let storageRoot = "/Users/test/.claude"
        store.providerStorageFootprints[.claude] = ProviderStorageFootprint(
            provider: .claude,
            totalBytes: 1024,
            paths: [storageRoot],
            missingPaths: [],
            unreadablePaths: [],
            components: [.init(path: storageRoot, totalBytes: 1024)],
            updatedAt: Date())
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 0.12,
            last30DaysTokens: 123,
            last30DaysCostUSD: 1.23,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 123,
                    costUSD: 1.23,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date()), provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)
        let usageHistoryIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "usageHistorySubmenu"
        })
        let storageIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardStorage"
        })
        let costIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardCost"
        })
        #expect(usageHistoryIndex < costIndex)
        #expect(costIndex < storageIndex)
        #expect(menu.items[usageHistoryIndex].title == "Plan Usage")
        #expect(menu.items[storageIndex].view == nil)
        #expect(menu.items[storageIndex].title.hasPrefix("Storage"))
        #expect(menu.items[storageIndex].title.contains("1 KB"))
        #expect(menu.items[storageIndex + 1].isSeparatorItem)
        #expect(!zip(menu.items, menu.items.dropFirst()).contains { first, second in
            first.isSeparatorItem && second.isSeparatorItem
        })
    }

    @Test
    func `opencodego usage card and cost row both open cost history`() throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .opencodego
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        self.enableOnlyOpenCodeGo(settings)

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let opencodegoSnapshot = OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 12,
            weeklyUsagePercent: 57,
            monthlyUsagePercent: 34,
            rollingResetInSec: 3600,
            weeklyResetInSec: 86400,
            monthlyResetInSec: 864_000,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    requestCount: 5,
                    costUSD: 1.23,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date())
        let opencodegoUsageSnapshot = opencodegoSnapshot.toUsageSnapshot()
        store._setSnapshotForTesting(opencodegoUsageSnapshot, provider: .opencodego)
        // A completed refresh also caches the projected token snapshot (UsageStore+Refresh.swift);
        // populate it here so `openAIWebContext.hasCostHistory` matches real post-refresh state.
        store._setTokenSnapshotForTesting(
            store.tokenSnapshot(fromProviderSnapshot: opencodegoUsageSnapshot, provider: .opencodego),
            provider: .opencodego)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .opencodego)
        controller.menuWillOpen(menu)

        let usageIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardUsage"
        })
        let usageHistoryIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "usageHistorySubmenu"
        })
        let costIndex = try #require(menu.items.firstIndex {
            ($0.representedObject as? String) == "menuCardCost"
        })

        #expect(menu.items[usageIndex].submenu?.items.contains {
            ($0.representedObject as? String) == "costHistoryChart"
        } == true)
        #expect(menu.items[usageHistoryIndex].title == "Plan Usage")
        #expect(usageIndex < usageHistoryIndex)
        #expect(usageHistoryIndex < costIndex)
        #expect(menu.items[costIndex].submenu != nil)
    }

    @Test
    func `claude detail card with inline cost chart opens cost history`() throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        self.enableOnly(.claude, settings: settings)

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 0.12,
            last30DaysTokens: 123,
            last30DaysCostUSD: 1.23,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 123,
                    costUSD: 1.23,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date()), provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)
        let usageItem = try #require(menu.items.first {
            ($0.representedObject as? String) == "menuCardUsage"
        })

        #expect(usageItem.submenu?.items.contains {
            ($0.representedObject as? String) == "costHistoryChart"
        } == true)
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuNativeSectionSpacingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        settings.providerDetectionCompleted = true
        return settings
    }

    private func enableOnly(_ enabledProvider: UsageProvider, settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == enabledProvider)
        }
    }

    private func enableOnlyOpenCodeGo(_ settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .opencodego)
        }
    }
}
