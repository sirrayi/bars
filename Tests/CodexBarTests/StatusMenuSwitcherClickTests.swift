import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuSwitcherClickTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        // Use the real system status bar in tests. Creating standalone NSStatusBar instances
        // has caused AppKit teardown crashes under swiftpm-testing-helper.
        .system
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuSwitcherClickTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore)
    }

    private func makeInstalledSwitcherShortcutMonitor() -> (controller: StatusItemController, menu: StatusItemMenu) {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = StatusItemMenu()
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: true,
            width: 320,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { _ in })
        let switcherItem = NSMenuItem()
        switcherItem.view = switcher
        menu.addItem(switcherItem)
        menu.addItem(.separator())

        controller.installProviderSwitcherShortcutMonitorIfNeeded(for: menu)
        return (controller, menu)
    }

    @Test
    func `merged switcher routes runtime clicks after overview round-trip`() throws {
        // Regression test for #867: after Provider → Overview, subsequent runtime clicks on a
        // sub-provider tab dropped through NSButton's tracking and never updated state.
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        // Step 1: provider → Overview via the runtime click path.
        let switcher1 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher1._test_simulateRuntimeClick(buttonTag: 0))
        #expect(settings.mergedMenuLastSelectedWasOverview == true)

        // Step 2: Overview → provider via the runtime click path. Tag 2 is the second provider
        // (claude) since tag 0 is Overview and tag 1 is the first provider.
        let switcher2 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher2._test_simulateRuntimeClick(buttonTag: 2))
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .claude)

        // Step 3: provider → Overview again.
        let switcher3 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher3._test_simulateRuntimeClick(buttonTag: 0))
        #expect(settings.mergedMenuLastSelectedWasOverview == true)

        // Step 4: Overview → other provider. This is the click that previously got dropped.
        let switcher4 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher4._test_simulateRuntimeClick(buttonTag: 1))
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .codex)
    }

    @Test
    func `merged switcher commits selection on matching mouse up`() throws {
        var selections: [ProviderSwitcherSelection] = []
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: true,
            width: 320,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { selections.append($0) })

        #expect(switcher._test_simulateMouseDown(buttonTag: 0))
        #expect(selections.isEmpty)
        let mouseUp = try #require(switcher._test_mouseUpEvent(buttonTag: 0))
        #expect(switcher.handleMenuTrackingMouseUp(mouseUp))
        #expect(selections == [.overview])
    }

    @Test
    func `menu tracking routes switcher pointer sequence before AppKit menu dispatch`() throws {
        var selected: ProviderSwitcherSelection?
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: true,
            width: 320,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { selected = $0 })
        let menu = StatusItemMenu()
        let item = NSMenuItem()
        item.view = switcher
        item.isEnabled = false
        menu.addItem(item)

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let fetcher = UsageFetcher()
        let controller = StatusItemController(
            store: UsageStore(
                fetcher: fetcher,
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings),
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let mouseDown = try #require(switcher._test_mouseDownEvent(buttonTag: 0))
        let mouseUp = try #require(switcher._test_mouseUpEvent(buttonTag: 0))
        #expect(controller.handleProviderSwitcherTrackingEvent(mouseDown, menu: menu))
        #expect(selected == nil)
        #expect(controller.handleProviderSwitcherTrackingEvent(mouseUp, menu: menu))
        #expect(selected == .overview)
    }

    @Test
    func `merged switcher runtime click defers icon rendering until after event handling`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.applyIcon(phase: nil)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=codex") == true)

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let switcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher._test_simulateRuntimeClick(buttonTag: 2))

        #expect(settings.selectedMenuProvider == .claude)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=codex") == true)
        await controller.providerSelectionUIRefreshTask?.value
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=claude") == true)
    }

    @Test
    func `merged switcher click marks menu stale before deferred rebuild`() throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = UInt64.max
        defer { controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = nil }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)

        let openedVersion = controller.menuContentVersion
        let switcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher._test_simulateRuntimeClick(buttonTag: 2))

        #expect(settings.selectedMenuProvider == .claude)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] != controller.menuContentVersion)

        controller.menuDidClose(menu)
        #expect(controller.menuVersions[key] != controller.menuContentVersion)
        #expect(controller.openMenuRebuildTasks[key] == nil)
    }

    @Test
    func `merged switcher runtime click updates loading animation state after event handling`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.applyIcon(phase: nil)
        #expect(controller.needsMenuBarIconAnimation() == false)
        #expect(controller.animationDriver == nil)

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let switcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher._test_simulateRuntimeClick(buttonTag: 2))
        #expect(settings.selectedMenuProvider == .claude)
        await controller.providerSelectionUIRefreshTask?.value
        #expect(controller.needsMenuBarIconAnimation() == true)
        #expect(controller.animationDriver != nil)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=claude") == true)

        #expect(switcher._test_simulateRuntimeClick(buttonTag: 1))
        #expect(settings.selectedMenuProvider == .codex)
        await controller.providerSelectionUIRefreshTask?.value
        #expect(controller.needsMenuBarIconAnimation() == false)
        #expect(controller.animationDriver == nil)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=codex") == true)
    }

    @Test
    func `merged switcher handles left and right arrow keyboard navigation`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }
        settings.setMergedOverviewProviderSelection(
            provider: .codex,
            isSelected: false,
            activeProviders: [.codex, .claude])
        settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: [.codex, .claude])

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        controller.menuRefreshEnabledOverrideForTesting = true
        defer { controller.releaseStatusItemsForTesting() }

        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.menuWillOpen(menu)
        #expect(menu.items.first?.view is ProviderSwitcherView)
        store.tokenRefreshInFlight.insert(.codex)
        defer { store.tokenRefreshInFlight.remove(.codex) }
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        #expect(try menu.performKeyEquivalent(with: Self.arrowKeyEvent(keyCode: 124)) == true)
        for _ in 0..<100 where rebuildCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .claude)
        #expect(rebuildCount == 1)

        #expect(try menu.performKeyEquivalent(with: Self.arrowKeyEvent(keyCode: 123)) == true)
        for _ in 0..<100 where rebuildCount == 1 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .codex)
        #expect(rebuildCount == 2)
    }

    @Test
    func `provider shortcut monitor is removed when tracked menu closes after switcher rebuild`() {
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let (controller, menu) = self.makeInstalledSwitcherShortcutMonitor()
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.providerSwitcherShortcutEventMonitor != nil)
        #expect(controller.providerSwitcherShortcutMenuID == ObjectIdentifier(menu))

        menu.removeAllItems()
        controller.menuDidClose(menu)

        #expect(controller.providerSwitcherShortcutEventMonitor == nil)
        #expect(controller.providerSwitcherShortcutMenuID == nil)
    }

    @Test
    func `switcher shortcut monitor is removed from direct close cleanup`() {
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let (controller, menu) = self.makeInstalledSwitcherShortcutMonitor()
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.providerSwitcherShortcutEventMonitor != nil)
        #expect(controller.providerSwitcherShortcutMenuID == ObjectIdentifier(menu))

        controller.forgetClosedMenu(menu)

        #expect(controller.providerSwitcherShortcutEventMonitor == nil)
        #expect(controller.providerSwitcherShortcutMenuID == nil)
    }

    private static func arrowKeyEvent(keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode))
    }

    private static func commandKeyEvent(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode))
    }
}
