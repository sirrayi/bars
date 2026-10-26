import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemAnimationSignatureTests {
    @Test
    func `merged icon only content repairs stale title when cached render is skipped`() throws {
        let suite = "StatusItemAnimationSignatureTests-merged-icon-only-title-restore"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarShowsBrandIconWithPercent = false

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 23, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)

        controller.applyIcon(phase: nil)
        let button = try #require(controller.statusItem.button)
        button.title = " stale"
        button.imagePosition = .imageLeft

        let skipped = controller.applyIcon(phase: nil)

        #expect(skipped)
        #expect(button.title.isEmpty)
        #expect(button.imagePosition == .imageOnly)
    }

    @Test
    func `inactive display contrast embeds the brand and restores standard content when disabled`() throws {
        let suite = "StatusItemAnimationSignatureTests-inactive-display-contrast"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarHighContrastOnInactiveDisplays = true
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 23, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)

        let displayText = try #require(controller.menuBarDisplayText(for: .codex, snapshot: snapshot))
        let expectedTitle = StatusItemController.buttonTitle(displayText, hasImage: true)
        controller.applyIcon(phase: nil)
        let button = try #require(controller.statusItem.button)

        #expect(button.image == nil)
        #expect(button.imagePosition == .noImage)
        #expect(button.attributedTitle.string == "\u{FFFC}\(expectedTitle)")
        #expect(button.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)

        #expect(controller.prepareButtonForImageOnlyCacheHit(button))
        #expect(button.image == nil)
        #expect(button.imagePosition == .noImage)
        #expect(button.attributedTitle.string == "\u{FFFC}\(expectedTitle)")
        #expect(button.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)

        button.attributedTitle = NSAttributedString()
        #expect(!controller.prepareButtonForImageOnlyCacheHit(button))

        controller.applyIcon(phase: nil)
        #expect(button.attributedTitle.string == "\u{FFFC}\(expectedTitle)")
        #expect(button.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)

        settings.menuBarIconStyle = .critters
        let critterSkipped = controller.applyIcon(phase: nil)

        #expect(!critterSkipped)
        #expect(button.image != nil)
        #expect(button.title.isEmpty)
        #expect(button.imagePosition == .imageOnly)
        #expect(button.attributedTitle.length == 0)

        settings.menuBarIconStyle = .iconAndPercent
        controller.applyIcon(phase: nil)

        #expect(button.image == nil)
        #expect(button.imagePosition == .noImage)
        #expect(button.attributedTitle.string == "\u{FFFC}\(expectedTitle)")
        #expect(button.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)

        settings.menuBarHighContrastOnInactiveDisplays = false
        let skipped = controller.applyIcon(phase: nil)

        #expect(!skipped)
        #expect(button.image != nil)
        #expect(button.title == expectedTitle)
        #expect(button.imagePosition == .imageLeft)
        #expect(button.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
    }

    @Test
    func `merged icon status indicator follows rendered provider`() throws {
        let suite = "StatusItemAnimationSignatureTests-merged-status-provider-scope"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = true
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarShowsBrandIconWithPercent = false

        let registry = ProviderRegistry.shared
        let codexMeta = try #require(registry.metadata[.codex])
        let claudeMeta = try #require(registry.metadata[.claude])
        settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store.statuses[.claude] = ProviderStatus(
            indicator: .major,
            description: "Claude status issue",
            updatedAt: Date(timeIntervalSince1970: 20))

        controller.applyIcon(phase: nil)

        #expect(controller.primaryProviderForUnifiedIcon() == .codex)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=codex") == true)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("status=none") == true)

        settings.selectedMenuProvider = .claude
        controller.applyIcon(phase: nil)

        #expect(controller.primaryProviderForUnifiedIcon() == .claude)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=claude") == true)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("status=major") == true)
    }

    @Test
    func `highest usage icon ranks only overview providers`() throws {
        let suite = "StatusItemAnimationSignatureTests-highest-usage-overview-subset"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.menuBarShowsHighestUsage = true

        let registry = ProviderRegistry.shared
        let codexMeta = try #require(registry.metadata[.codex])
        let claudeMeta = try #require(registry.metadata[.claude])
        settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: store.enabledProvidersForDisplay())
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .claude)

        #expect(store.providerWithHighestUsage()?.provider == .claude)
        #expect(controller.primaryProviderForUnifiedIcon() == .codex)
    }

    @Test(arguments: [nil, 100.0] as [Double?])
    func `highest usage icon keeps nonempty overview authoritative when unrankable`(
        overviewUsedPercent: Double?) throws
    {
        let suite = "StatusItemAnimationSignatureTests-highest-usage-overview-fallback"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.menuBarShowsHighestUsage = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        let codexMeta = try #require(registry.metadata[.codex])
        let claudeMeta = try #require(registry.metadata[.claude])
        settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: store.enabledProvidersForDisplay())
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        if let overviewUsedPercent {
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: overviewUsedPercent,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                provider: .codex)
        }
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .claude)

        #expect(store.providerWithHighestUsage(candidateProviders: [.codex]) == nil)
        #expect(controller.primaryProviderForUnifiedIcon() == .codex)
    }

    @Test
    func `highest usage icon allows broad fallback for explicit empty overview`() throws {
        let suite = "StatusItemAnimationSignatureTests-highest-usage-empty-overview"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.menuBarShowsHighestUsage = true
        settings.selectedMenuProvider = .claude

        let registry = ProviderRegistry.shared
        let codexMeta = try #require(registry.metadata[.codex])
        let claudeMeta = try #require(registry.metadata[.claude])
        settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let activeProviders = store.enabledProvidersForDisplay()
        settings.setMergedOverviewProviderSelection(
            provider: .codex,
            isSelected: false,
            activeProviders: activeProviders)
        settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: activeProviders)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(settings.resolvedMergedOverviewProviders(
            activeProviders: store.enabledProvidersForDisplay()) == [])
        #expect(controller.primaryProviderForUnifiedIcon() == .claude)
    }

    @Test
    func `split provider icon skips unchanged render signature`() throws {
        let suite = "StatusItemAnimationSignatureTests-split-provider-signature"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.menuBarShowsBrandIconWithPercent = false

        if let codexMeta = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)

        #expect(controller.applyIcon(for: .codex, phase: nil) == false)
        let button = try #require(controller.statusItems[.codex]?.button)
        button.title = " stale"
        button.imagePosition = .imageLeft

        #expect(controller.applyIcon(for: .codex, phase: nil) == true)
        #expect(button.title.isEmpty)
        #expect(button.imagePosition == .imageOnly)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)

        #expect(controller.applyIcon(for: .codex, phase: nil) == false)
    }
}
