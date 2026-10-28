import BarsCore
import Foundation
import Testing
@testable import Bars

@MainActor
extension StatusMenuTests {
    @Test
    func `claude menu shows costs inline without cost or plan usage submenus`() throws {
        self.disableMenuCardsForTesting()

        for style in CostSummaryDisplayStyle.allCases {
            let settings = self.makeSettings()
            settings.statusChecksEnabled = false
            settings.refreshFrequency = .manual
            settings.mergeIcons = true
            settings.selectedMenuProvider = .claude
            settings.costUsageEnabled = true
            settings.costSummaryDisplayStyle = style

            enableTestProviders([.claude], settings: settings)

            let store = UsageStore(
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
            store._setTokenSnapshotForTesting(
                CostUsageTokenSnapshot(
                    sessionTokens: 85_000_000,
                    sessionCostUSD: 91.63,
                    last30DaysTokens: 1_100_000_000,
                    last30DaysCostUSD: 1001.27,
                    daily: [
                        CostUsageDailyReport.Entry(
                            date: "2026-06-23",
                            inputTokens: nil,
                            outputTokens: nil,
                            totalTokens: 85_000_000,
                            costUSD: 91.63,
                            modelsUsed: ["fictional-test-model"],
                            modelBreakdowns: nil),
                    ],
                    updatedAt: Date()),
                provider: .claude)

            let controller = StatusItemController(
                store: store,
                settings: settings,
                account: AccountInfo(email: nil, plan: nil),
                updater: DisabledUpdaterController(),
                preferencesSelection: PreferencesSelection(),
                statusBar: self.makeStatusBarForTesting())
            defer { controller.releaseStatusItemsForTesting() }

            let model = try #require(controller.menuCardModel(for: .claude))
            let providerDetailModel = ProvidersPane(settings: settings, store: store)
                ._test_menuCardModel(for: .claude)
            let menu = controller.makeMenu()
            controller.menuWillOpen(menu)

            // A stored legacy style must not bring back the removed Cost row or hover submenus.
            let ids = menu.items.compactMap { $0.representedObject as? String }
            #expect(model.inlineUsageDashboard != nil)
            #expect(model.tokenUsage == nil)
            #expect(providerDetailModel.tokenUsage != nil)
            #expect(!ids.contains("menuCardCost"))
            #expect(!ids.contains("usageHistorySubmenu"))
            #expect(menu.items.allSatisfy { $0.submenu == nil || $0.title == L("Status Page") })
        }
    }
}
