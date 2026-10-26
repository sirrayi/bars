import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemLayoutStyleSwitchTests {
    @Test(arguments: [false, true])
    func `stored layout invalidates meter signatures before switching back`(merged: Bool) throws {
        let settings = testSettingsStore(
            suiteName: "StatusItemLayoutStyleSwitchTests-\(merged)",
            userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = merged
        settings.selectedMenuProvider = .opencode
        settings.menuBarIconStyle = .bars
        enableTestProviders([.opencode, .claude], settings: settings)
        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .opencode)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        func render() -> Bool {
            merged ? controller.applyIcon(phase: nil) : controller.applyIcon(for: .opencode, phase: nil)
        }
        _ = render()
        let button = try #require(merged ? controller.statusItem.button : controller.statusItems[.opencode]?.button)
        let meter = try #require(button.image)
        #expect(render())

        settings.setMenuBarLayout(MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]), for: nil)
        settings.menuBarIconStyle = .iconAndPercent
        _ = render()
        #expect(button.image !== meter)
        #expect(controller.lastAppliedMergedIconRenderSignature == nil)
        #expect(controller.lastAppliedProviderIconRenderSignatures[.opencode] == nil)

        settings.menuBarIconStyle = .bars
        #expect(!render())
        #expect(button.image?.tiffRepresentation == meter.tiffRepresentation)
        #expect(render())
    }
}
