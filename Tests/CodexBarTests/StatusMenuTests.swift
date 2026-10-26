import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuTests {
    func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
    }

    func makeStatusBarForTesting() -> NSStatusBar {
        // Use the real system status bar in tests. Creating standalone NSStatusBar instances
        // has caused AppKit teardown crashes under swiftpm-testing-helper.
        .system
    }

    func makeSettings() -> SettingsStore {
        let suite = "StatusMenuTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore)
        settings.providerDetectionCompleted = true
        return settings
    }

    func makeOpenCodeStore(settings: SettingsStore) -> UsageStore {
        let now = Date()
        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 22,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .opencode,
                    accountEmail: "opencode@example.com",
                    accountOrganization: nil,
                    loginMethod: "Plus Plan")),
            provider: .opencode)
        return store
    }

    private func switcherButtons(in menu: NSMenu) -> [NSButton] {
        guard let switcherView = menu.items.first?.view as? ProviderSwitcherView else { return [] }
        return switcherView.subviews
            .compactMap { $0 as? NSButton }
            .sorted { $0.tag < $1.tag }
    }

    private func representedIDs(in menu: NSMenu) -> [String] {
        menu.items.compactMap { $0.representedObject as? String }
    }

    @Test
    func `opencode go dashboard action follows configured workspace`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.opencodegoWorkspaceID = "https://opencode.ai/workspace/wrk_abc123/go"

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        // A legacy workspace URL still resolves, but the action opens the console route.
        #expect(controller.dashboardURL(for: .opencodego)?
            .absoluteString == "https://opencode.ai/console/wrk_abc123/go")
    }

    @Test
    func `claude dashboard action opens usage page for account type`() {
        let cases: [(String?, String)] = [
            (nil, "https://platform.claude.com/usage"),
            ("API", "https://platform.claude.com/usage"),
            ("Claude Enterprise", "https://platform.claude.com/usage"),
            ("Claude Pro", "https://claude.ai/settings/usage"),
            ("Claude Max", "https://claude.ai/settings/usage"),
            ("Claude Team", "https://claude.ai/settings/usage"),
            ("Claude Ultra", "https://claude.ai/settings/usage"),
        ]
        for (plan, expectedURL) in cases {
            self.disableMenuCardsForTesting()
            let settings = self.makeSettings()
            settings.statusChecksEnabled = false
            settings.refreshFrequency = .manual

            let store = UsageStore(
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 12,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: nil),
                    secondary: nil,
                    tertiary: nil,
                    updatedAt: Date(),
                    identity: ProviderIdentitySnapshot(
                        providerID: .claude,
                        accountEmail: nil,
                        accountOrganization: nil,
                        loginMethod: plan)),
                provider: .claude)
            let controller = StatusItemController(
                store: store,
                settings: settings,
                account: AccountInfo(email: nil, plan: nil),
                updater: DisabledUpdaterController(),
                preferencesSelection: PreferencesSelection(),
                statusBar: self.makeStatusBarForTesting())

            #expect(controller.dashboardURL(for: .claude)?.absoluteString == expectedURL)
        }
    }

    @Test
    func `merged menu open does not persist resolved provider when selection is nil`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = nil

        enableTestProviders([.opencode, .claude], settings: settings)

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let expectedResolved = store.enabledProviders().first ?? .opencode
        #expect(store.enabledProviders().count > 1)
        #expect(controller.shouldMergeIcons == true)
        let menu = controller.makeMenu()
        #expect(settings.selectedMenuProvider == nil)
        controller.menuWillOpen(menu)
        #expect(settings.selectedMenuProvider == nil)
        #expect(controller.lastMenuProvider == expectedResolved)
    }

    @Test
    func `shortcut closes tracked menu instead of queueing another open`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        #expect(controller.openMenus[key] != nil)

        #expect(controller.closeOpenMenusFromShortcutIfNeeded() == true)
        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuRefreshTasks.isEmpty)
        #expect(controller.closeOpenMenusFromShortcutIfNeeded() == false)
    }

    @Test
    func `open menu defers store data refresh until next open`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.resetMenuRefreshEnabledForTesting() }
        let openedVersion = controller.menuVersions[key]

        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 11,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .opencode,
                    accountEmail: "opencode@example.com",
                    accountOrganization: nil,
                    loginMethod: "Plus Plan")),
            provider: .opencode)

        for _ in 0..<50 where controller.menuContentVersion == openedVersion {
            await Task.yield()
        }

        let staleVersion = controller.menuContentVersion
        controller.refreshOpenMenusIfNeeded()

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        controller.menuDidClose(menu)
        controller.menuWillOpen(menu)
        #expect(controller.menuVersions[key] == staleVersion)
    }

    @Test
    func `delayed menu refresh skips when refresh disabled during delay`() async {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        StatusItemController.setMenuOpenRefreshDelayForTesting(.milliseconds(50))
        defer {
            StatusItemController.resetMenuOpenRefreshDelayForTesting()
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        var delayedRefreshWakeCount = 0

        await withStatusItemControllerForTesting(
            store: store,
            settings: settings,
            statusBar: self.makeStatusBarForTesting())
        { controller in
            controller.onDelayedMenuRefreshAttemptForTesting = {
                delayedRefreshWakeCount += 1
            }
            let menu = controller.makeMenu()
            controller.menuWillOpen(menu)
            controller.menuRefreshEnabledOverrideForTesting = false
            try? await Task.sleep(for: .milliseconds(180))
        }

        #expect(delayedRefreshWakeCount == 0)
    }

    @Test
    func `login state callbacks do not attach menus after release`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        controller.releaseStatusItemsForTesting()
        #expect(controller.statusItem.menu == nil)
        #expect(controller.statusItems.isEmpty)

        controller.activeLoginProvider = .opencode
        let loginTask = Task<Void, Never> {}
        controller.loginTask = loginTask
        loginTask.cancel()
        controller.loginTask = nil
        controller.activeLoginProvider = nil

        #expect(controller.statusItem.menu == nil)
        #expect(controller.statusItems.isEmpty)
    }

    @Test
    func `open merged menu rebuilds switcher when usage bars mode changes`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .opencode
        settings.usageBarsShowUsed = false

        enableTestProviders([.opencode, .claude], settings: settings)

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        #expect(store.enabledProviders().count == 2)
        #expect(controller.shouldMergeIcons == true)

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        controller.openMenus[ObjectIdentifier(menu)] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let initialSwitcher = menu.items.first?.view as? ProviderSwitcherView
        #expect(initialSwitcher != nil)
        let initialSwitcherID = initialSwitcher.map(ObjectIdentifier.init)

        settings.usageBarsShowUsed = true
        controller.handleProviderConfigChange(reason: "usageBarsShowUsed")
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(controller.parentMenuRebuildsDeferredDuringTracking.contains(ObjectIdentifier(menu)))
        if let initialSwitcherID, let currentSwitcher = menu.items.first?.view as? ProviderSwitcherView {
            #expect(initialSwitcherID == ObjectIdentifier(currentSwitcher))
        }

        controller.menuDidClose(menu)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let updatedSwitcher = menu.items.first?.view as? ProviderSwitcherView
        #expect(updatedSwitcher != nil)
        if let initialSwitcherID, let updatedSwitcher {
            #expect(initialSwitcherID != ObjectIdentifier(updatedSwitcher))
        }
    }

    @Test
    func `merged switcher includes overview tab when multiple providers enabled`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = false

        enableTestProviders([.opencode, .claude], settings: settings)

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let buttons = self.switcherButtons(in: menu)
        #expect(buttons.count == store.enabledProvidersForDisplay().count + 1)
        #expect(buttons.contains(where: { $0.tag == 0 }))
        #expect(buttons.first(where: { $0.state == .on })?.tag == 1)
    }

    @Test
    func `merged switcher overview selection persists without overwriting provider selection`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = false

        enableTestProviders([.opencode, .claude], settings: settings)

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let overviewButton = self.switcherButtons(in: menu).first(where: { $0.tag == 0 })
        #expect(overviewButton != nil)
        overviewButton?.performClick(nil)

        #expect(settings.mergedMenuLastSelectedWasOverview == true)
        #expect(settings.selectedMenuProvider == .claude)

        controller.menuDidClose(menu)

        let reopenedMenu = controller.makeMenu()
        controller.menuWillOpen(reopenedMenu)
        let reopenedSelectedTag = self.switcherButtons(in: reopenedMenu).first(where: { $0.state == .on })?.tag
        #expect(reopenedSelectedTag == 0)
        #expect(settings.selectedMenuProvider == .claude)
    }

    @Test
    func `open menu rebuilds switcher when overview availability changes`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .opencode
        settings.mergedMenuLastSelectedWasOverview = false

        enableTestProviders([.opencode, .claude], settings: settings)

        let activeProviders: [ProviderInstanceID] = [.opencode, .claude]
        _ = settings.setMergedOverviewProviderSelection(
            provider: .opencode,
            isSelected: false,
            activeProviders: activeProviders)
        _ = settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: activeProviders)

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        controller.openMenus[ObjectIdentifier(menu)] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let initialButtons = self.switcherButtons(in: menu)
        #expect(initialButtons.count == activeProviders.count)

        _ = settings.setMergedOverviewProviderSelection(
            provider: .opencode,
            isSelected: true,
            activeProviders: activeProviders)
        controller.menuContentVersion &+= 1
        controller.menuDidClose(menu)
        controller.menuWillOpen(menu)

        let updatedButtons = self.switcherButtons(in: menu)
        #expect(updatedButtons.count == activeProviders.count + 1)
    }
}

@MainActor
extension StatusMenuTests {
    @Test
    func `status blurb uses wrapped view-backed menu item`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = true
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        enableTestProviders([.opencode], settings: settings)

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let statusText = "An SSL error has occurred and a secure connection to the server cannot be made."
        store.statuses[.opencode] = ProviderStatus(
            indicator: .critical,
            description: statusText,
            updatedAt: nil)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu(for: .opencode)
        controller.menuWillOpen(menu)

        let statusItem = menu.items.first(where: { $0.toolTip == statusText })
        #expect(statusItem != nil)
        #expect(statusItem?.view != nil)
        #expect(statusItem?.title.isEmpty == true)
        #expect(statusItem?.view?.frame.width == 310)
    }

    @Test
    func `hosted storage submenu is height capped and scroll enabled`() {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.providerStorageFootprintsEnabled = true

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let root = "/Users/test/.claude"
        store.providerStorageFootprints[.claude] = ProviderStorageFootprint(
            provider: .claude,
            totalBytes: 1_756_000_000,
            paths: [root],
            missingPaths: [],
            unreadablePaths: [],
            components: [
                .init(path: "\(root)/projects", totalBytes: 1_500_000_000),
                .init(path: "\(root)/file-history", totalBytes: 103_000_000),
                .init(path: "\(root)/telemetry", totalBytes: 51_000_000),
                .init(path: "\(root)/plugins", totalBytes: 33_000_000),
                .init(path: "\(root)/history.jsonl", totalBytes: 3_800_000),
                .init(path: "\(root)/shell-snapshots", totalBytes: 1_500_000),
                .init(path: "\(root)/plans", totalBytes: 1_100_000),
                .init(path: "\(root)/paste-cache", totalBytes: 541_000),
                .init(path: "\(root)/session-env", totalBytes: 208_000),
                .init(path: "\(root)/todos", totalBytes: 6700),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let submenu = NSMenu()
        let didAppend = controller.appendStorageBreakdownItem(to: submenu, provider: .claude, width: 310)

        #expect(didAppend)
        let item = submenu.items.first
        #expect(item?.isEnabled == true)
        #expect((item?.view?.frame.height ?? 0) <= 620)
    }

    @Test
    func `hosted cost submenu preserves provider context after empty hydration`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.opencode] {
            settings.setProviderEnabled(provider: .opencode, metadata: codexMeta, enabled: true)
        }

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .opencode)
        #expect(submenu.autoenablesItems == false)
        #expect(submenu.items.first?.isEnabled == true)

        controller.hydrateHostedSubviewMenuIfNeeded(submenu)
        #expect(submenu.items.count == 1)
        #expect(submenu.items.first?.title == "No data available")
        #expect(submenu.items.first?.toolTip == UsageProvider.opencode.rawValue)

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
            updatedAt: Date()), provider: .opencode)

        controller.hydrateHostedSubviewMenuIfNeeded(submenu)
        #expect(submenu.items.count == 1)
        #expect(submenu.items.first?.title != "No data available")
        #expect(submenu.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
        #expect(submenu.items.first?.isEnabled == true)
    }
}

extension StatusMenuTests {
    @Test
    func `overview rows keep menu item action in rendered mode`() throws {
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer { self.disableMenuCardsForTesting() }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .opencode
        settings.mergedMenuLastSelectedWasOverview = true

        enableTestProviders([.opencode, .claude], settings: settings)

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let claudeRow = try #require(menu.items.first {
            ($0.representedObject as? String) == "overviewRow-claude"
        })
        #expect(claudeRow.action != nil)
        #expect(claudeRow.target is StatusItemController)
    }
}
