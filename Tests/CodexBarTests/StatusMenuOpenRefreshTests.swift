import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `store observation marks open menu stale without rebuilding during tracking`() async {
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
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = controller.menuVersions[key]
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }

        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 33,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: "codex@example.com",
                    accountOrganization: nil,
                    loginMethod: "Plus Plan")),
            provider: .claude)

        for _ in 0..<20 where controller.menuContentVersion == openedVersion {
            await Task.yield()
        }

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)
        #expect(rebuildCount == 0)
    }

    @Test
    func `closed merged menu defers rebuild until next open instead of pre-warming`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.statusItem.menu = menu
        for _ in 0..<20 {
            await Task.yield()
        }

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        for _ in 0..<40 {
            await Task.yield()
        }
        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        controller.cancelAllClosedMenuRebuilds()
        controller.closedMenusDeferredUntilNextOpen.removeAll(keepingCapacity: false)
        let openedVersion = controller.menuVersions[key]

        // Background data-refresh tick (stale allowed): closed prep is skipped entirely, so
        // the closed merged menu must not be pre-warmed or marked deferred.
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        for _ in 0..<40 {
            await Task.yield()
        }
        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)
        #expect(!controller.closedMenusDeferredUntilNextOpen.contains(key))

        // A required (non-stale) invalidation must also leave the closed merged menu deferred.
        controller.invalidateMenus()
        for _ in 0..<40 {
            await Task.yield()
        }
        #expect(controller.menuVersions[key] == openedVersion)
        #expect(controller.closedMenusDeferredUntilNextOpen.contains(key))

        // The deferred merged menu is repopulated synchronously on the next open.
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
        #expect(!controller.closedMenusDeferredUntilNextOpen.contains(key))
    }

    @Test
    func `data refresh invalidation does not rebuild closed non merged attached menu`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        // Use a non-merged attached menu: stale data-refresh invalidations should not pre-warm any
        // closed attached menu, while required invalidations still may prepare non-merged menus.
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        for _ in 0..<40 {
            await Task.yield()
        }
        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        controller.cancelAllClosedMenuRebuilds()
        let openedVersion = controller.menuVersions[key]

        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        for _ in 0..<40 {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        for _ in 0..<40 where controller.menuVersions[key] != controller.menuContentVersion {
            await Task.yield()
        }
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `required non merged closed menu preparation survives later data refresh invalidation`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        // Use a non-merged attached menu so this covers the delayed closed-menu rebuild path. Merged
        // menus are intentionally deferred until next open on current main (#1274).
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        controller.invalidateMenus()
        let requiredVersion = controller.latestRequiredMenuRebuildVersion
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        for _ in 0..<40 where controller.menuVersions[key] == openedVersion {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(requiredVersion > (openedVersion ?? -1))
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `closed attached menu preparation waits for store refresh to finish`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        // Use a non-merged attached menu: the merged menu is intentionally never pre-warmed while
        // closed (#1274), so the in-flight-refresh prep machinery is exercised via the fallback menu.
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        store.isRefreshing = true
        controller.invalidateMenus()
        for _ in 0..<40 {
            await Task.yield()
        }

        #expect(controller.menuVersions[key] == openedVersion)

        store.isRefreshing = false
        controller.invalidateMenus()
        for _ in 0..<40 where controller.menuVersions[key] == openedVersion {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `closed attached menu preparation waits for token refresh to finish`() async {
        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        // Use a non-merged attached menu: the merged menu is intentionally never pre-warmed while
        // closed (#1274), so the in-flight-refresh prep machinery is exercised via the fallback menu.
        controller.fallbackMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        store.tokenRefreshInFlight.insert(.claude)
        controller.invalidateMenus()
        for _ in 0..<40 {
            await Task.yield()
        }

        #expect(controller.menuVersions[key] == openedVersion)

        store.tokenRefreshInFlight.remove(.claude)
        controller.invalidateMenus()
        for _ in 0..<40 where controller.menuVersions[key] == openedVersion {
            await Task.yield()
        }

        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `closed menu rebuild cleanup runs when weak menu disappears`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        let key: ObjectIdentifier
        do {
            let menu = NSMenu()
            key = ObjectIdentifier(menu)
            controller.rebuildClosedMenuIfNeeded(menu)
            #expect(controller.closedMenuRebuildTasks[key] != nil)
            #expect(controller.closedMenuRebuildTokens[key] != nil)
        }

        for _ in 0..<40 where controller.closedMenuRebuildTasks[key] != nil {
            await Task.yield()
        }

        #expect(controller.closedMenuRebuildTasks[key] == nil)
        #expect(controller.closedMenuRebuildTokens[key] == nil)
    }

    @Test
    func `merged menu close defers stale rebuild until next open`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.statusItem.menu = menu
        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        controller.menuWillOpen(menu)

        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]
        controller.invalidateMenus(refreshOpenMenus: false)
        #expect(controller.menuNeedsRefresh(menu))

        controller.menuDidClose(menu)
        await self.waitUntilClosedMenuRebuildRemainsDeferred(controller, key: key, openedVersion: openedVersion)

        #expect(controller.closedMenuRebuildTasks[key] == nil)
        #expect(controller.menuVersions[key] == openedVersion)

        controller.menuWillOpen(menu)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `menu open keeps stale nonempty content while store refresh is active`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]
        let openedItemCount = menu.items.count

        store.isRefreshing = true
        defer { store.isRefreshing = false }
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.menuVersions[key] == openedVersion)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(menu.items.count == openedItemCount)
        #expect(controller.openMenus[key] === menu)
    }

    @Test
    func `menu open rebuilds stale content after privacy setting changes during refresh`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        store.isRefreshing = true
        defer { store.isRefreshing = false }
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        settings.hidePersonalInfo = true
        controller.invalidateMenus()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.menuVersions[key] == controller.menuContentVersion)
        #expect(controller.menuVersions[key] != openedVersion)
    }

    @Test
    func `menu open keeps stale nonempty content while token refresh is active`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.statusItem.menu = menu

        controller.populateMenu(menu, provider: nil)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]
        let openedItemCount = menu.items.count

        store.tokenRefreshInFlight.insert(.claude)
        defer { store.tokenRefreshInFlight.remove(.claude) }
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.menuVersions[key] == openedVersion)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(menu.items.count == openedItemCount)
        #expect(controller.openMenus[key] === menu)
    }

    @Test
    func `explicit store actions defer visible parent menu rebuild`() async {
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
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = controller.menuVersions[key]
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.refreshOpenMenusAfterExplicitStoreAction()
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(controller.menuContentVersion != openedVersion)
        #expect(rebuildCount == 0)
        #expect(controller.menuVersions[key] == openedVersion)
        #expect(controller.parentMenuRebuildsDeferredDuringTracking.contains(key))
    }

    @Test
    func `repeated explicit store actions keep parent rebuild deferred`() async {
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
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.refreshOpenMenusAfterExplicitStoreAction()
        controller.refreshOpenMenusAfterExplicitStoreAction()
        controller.refreshOpenMenusAfterExplicitStoreAction()

        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(rebuildCount == 0)
        #expect(controller.menuVersions[key] != controller.menuContentVersion)
        #expect(controller.parentMenuRebuildsDeferredDuringTracking.contains(key))
    }

    @Test
    func `explicit refresh rebuilds stale parent after hosted submenu closes`() async {
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
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let menuKey = ObjectIdentifier(menu)
        controller.openMenus[menuKey] = menu

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .claude)
        let submenuKey = ObjectIdentifier(submenu)
        controller.openMenus[submenuKey] = submenu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = controller.menuVersions[menuKey]
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.refreshOpenMenusAfterExplicitStoreAction()
        for _ in 0..<20 where controller.menuContentVersion == openedVersion {
            await Task.yield()
        }
        #expect(controller.menuVersions[menuKey] == openedVersion)

        controller.menuDidClose(submenu)
        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(controller.openMenus[submenuKey] == nil)
        #expect(rebuildCount == 1)
        #expect(controller.menuVersions[menuKey] == controller.menuContentVersion)
        #expect(!controller.parentMenuRebuildsDeferredDuringTracking.contains(menuKey))
    }

    @Test
    func `hosted submenu close waits for active refresh before rebuilding parent`() async {
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
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let menuKey = ObjectIdentifier(menu)
        controller.openMenus[menuKey] = menu

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .claude)
        let submenuKey = ObjectIdentifier(submenu)
        controller.openMenus[submenuKey] = submenu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = controller.menuVersions[menuKey]
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        store.isRefreshing = true
        controller.refreshOpenMenusAfterExplicitStoreAction()
        controller.menuDidClose(submenu)
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(controller.openMenus[submenuKey] == nil)
        #expect(rebuildCount == 0)
        #expect(controller.menuVersions[menuKey] == openedVersion)
        #expect(controller.parentMenuRebuildPendingAfterHostedSubviewClose)

        store.isRefreshing = false
        controller.handleObservedStoreMenuChange()
        let rebuildDeadline = ContinuousClock.now + .seconds(2)
        while rebuildCount == 0, ContinuousClock.now < rebuildDeadline {
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(rebuildCount == 1)
        #expect(controller.menuVersions[menuKey] == controller.menuContentVersion)
        #expect(!controller.parentMenuRebuildPendingAfterHostedSubviewClose)
        #expect(!controller.parentMenuRebuildsDeferredDuringTracking.contains(menuKey))
    }

    @Test
    func `plain open menu refresh preserves pending switcher hosted submenu cleanup`() async {
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
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let menuKey = ObjectIdentifier(menu)
        controller.openMenus[menuKey] = menu

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .claude)
        let submenuKey = ObjectIdentifier(submenu)
        controller.openMenus[submenuKey] = submenu
        controller.menuRefreshEnabledOverrideForTesting = true

        var rootRebuildCount = 0
        controller._test_openMenuRebuildObserver = { rebuiltMenu in
            guard rebuiltMenu === menu else { return }
            rootRebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .claude)
        controller.refreshOpenMenuIfStillVisible(menu, provider: .claude)

        for _ in 0..<20 where rootRebuildCount == 0 {
            await Task.yield()
        }

        #expect(controller.openMenus[submenuKey] == nil)
        #expect(rootRebuildCount == 1)
        #expect(controller.menuVersions[menuKey] == controller.menuContentVersion)
    }

    @Test
    func `rapid switcher rebuild requests coalesce before populating open menu`() async {
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
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let menuKey = ObjectIdentifier(menu)
        controller.openMenus[menuKey] = menu
        controller.menuRefreshEnabledOverrideForTesting = true
        controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = 0
        defer { controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = nil }

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }
        var refreshGateEntries = 0
        var pendingRefreshGates: [CheckedContinuation<Void, Never>] = []
        func resumePendingRefreshGates() {
            let gates = pendingRefreshGates
            pendingRefreshGates.removeAll(keepingCapacity: true)
            for gate in gates {
                gate.resume()
            }
        }
        controller._test_openMenuRefreshYieldOverride = {
            refreshGateEntries += 1
            await withCheckedContinuation { continuation in
                pendingRefreshGates.append(continuation)
            }
        }
        defer {
            resumePendingRefreshGates()
            controller._test_openMenuRefreshYieldOverride = nil
        }

        controller.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .claude)
        for _ in 0..<20 where refreshGateEntries == 0 {
            await Task.yield()
        }
        #expect(refreshGateEntries == 1)
        #expect(rebuildCount == 0)

        controller.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .claude)
        resumePendingRefreshGates()
        for _ in 0..<20 where refreshGateEntries < 2 {
            await Task.yield()
        }
        #expect(refreshGateEntries == 2)
        #expect(rebuildCount == 0)
        resumePendingRefreshGates()

        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(rebuildCount == 1)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(rebuildCount == 1)
    }

    @Test
    func `token cost history arriving after open rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        #expect(self.menuItem(in: menu, id: "menuCardCost") == nil)

        store._setTokenSnapshotForTesting(self.makeCodexTokenCostSnapshot(), provider: .claude)

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)

        let costItem = try #require(self.menuItem(in: menu, id: "menuCardCost"))
        #expect(costItem.submenu?.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    @Test
    func `fresh token cost history with same day count rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        store._setTokenSnapshotForTesting(
            self.makeCodexTokenCostSnapshot(
                sessionTokens: 123,
                sessionCostUSD: 0.12,
                last30DaysTokens: 456,
                last30DaysCostUSD: 1.23,
                updatedAt: Date(timeIntervalSince1970: 100)),
            provider: .claude)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        _ = try #require(self.menuItem(in: menu, id: "menuCardCost"))

        store._setTokenSnapshotForTesting(
            self.makeCodexTokenCostSnapshot(
                sessionTokens: 999,
                sessionCostUSD: 0.99,
                last30DaysTokens: 888,
                last30DaysCostUSD: 8.88,
                updatedAt: Date(timeIntervalSince1970: 200)),
            provider: .claude)

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)

        let costItem = try #require(self.menuItem(in: menu, id: "menuCardCost"))
        #expect(costItem.submenu?.items.first?.representedObject as? String == StatusItemController.costHistoryChartID)
    }

    @Test
    func `plan utilization history arriving after open rebuilds parent menu after tracking ends`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        enableTestProviders([.claude], settings: settings)

        let store = self.makeOpenCodeStore(settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = try #require(controller.menuVersions[key])
        let usageHistoryItem = try #require(self.menuItem(in: menu, id: "usageHistorySubmenu"))
        #expect(usageHistoryItem.submenu?.items.first?.representedObject as? String == StatusItemController
            .usageHistoryChartID)
        let openedRevision = store.planUtilizationHistoryRevision

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.makeCodexPlanUtilizationSnapshot(),
            now: Date())

        await self.waitUntilOpenMenuStaysStale(controller, key: key, after: openedVersion)

        #expect(store.planUtilizationHistoryRevision > openedRevision)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        await self.closeMenuAndWaitUntilFresh(controller, menu: menu, key: key)
    }

    private func menuItem(in menu: NSMenu, id: String) -> NSMenuItem? {
        menu.items.first { ($0.representedObject as? String) == id }
    }

    private func waitUntilMenuVersionChanges(
        _ controller: StatusItemController,
        from version: Int?) async
    {
        for _ in 0..<20 where controller.menuContentVersion == version {
            await Task.yield()
        }
    }

    private func waitUntilOpenMenuStaysStale(
        _ controller: StatusItemController,
        key: ObjectIdentifier,
        after version: Int?) async
    {
        for _ in 0..<40 {
            guard controller.menuContentVersion != version else {
                await Task.yield()
                continue
            }
            guard controller.menuVersions[key] == version else {
                await Task.yield()
                continue
            }
            return
        }
    }

    private func closeMenuAndWaitUntilFresh(
        _ controller: StatusItemController,
        menu: NSMenu,
        key: ObjectIdentifier) async
    {
        controller.menuDidClose(menu)
        for _ in 0..<40 where controller.menuVersions[key] != controller.menuContentVersion {
            await Task.yield()
        }
        if controller.menuVersions[key] != controller.menuContentVersion {
            controller.menuWillOpen(menu)
        }
        for _ in 0..<40 where controller.menuVersions[key] != controller.menuContentVersion {
            await Task.yield()
        }
        #expect(controller.menuVersions[key] == controller.menuContentVersion)
    }

    private func waitUntilClosedMenuRebuildRemainsDeferred(
        _ controller: StatusItemController,
        key: ObjectIdentifier,
        openedVersion: Int?) async
    {
        for _ in 0..<40
            where controller.closedMenuRebuildTasks[key] != nil ||
            controller.menuVersions[key] != openedVersion
        {
            await Task.yield()
        }
    }

    private func makeCodexTokenCostSnapshot(
        sessionTokens: Int = 123,
        sessionCostUSD: Double = 0.12,
        last30DaysTokens: Int = 456,
        last30DaysCostUSD: Double = 1.23,
        updatedAt: Date = Date()) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCostUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-24",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: sessionTokens,
                    costUSD: last30DaysCostUSD,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: updatedAt)
    }

    private func makeCodexPlanUtilizationSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 35,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(1800),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 42,
                windowMinutes: 10080,
                resetsAt: Date().addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: "Plus Plan"))
    }

    /// The recent-interaction signal that `AdaptiveRefreshPolicy` reads has exactly one production
    /// entry point: `StatusItemController.menuWillOpen(_:)` calling `store.noteMenuOpened()`. Every
    /// other adaptive-refresh test drives `UsageStore` directly, so none of them would catch that
    /// wiring line being deleted — this test drives the real menu-open path instead.
    @Test
    func `menuWillOpen records the menu-open signal on the store`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = self.makeOpenCodeStore(settings: settings)
        #expect(store.lastMenuOpenAt == nil)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        #expect(store.lastMenuOpenAt != nil)
    }
}

private actor BlockingStatusMenuProviderRefresh {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = 0

    func awaitRelease() async {
        self.started += 1
        self.resumeStartWaiters()
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if self.started > 0 { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func resumeNext() {
        guard !self.continuations.isEmpty else { return }
        self.continuations.removeFirst().resume()
    }

    private func resumeStartWaiters() {
        let waiters = self.startWaiters
        self.startWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
