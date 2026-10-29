import AppKit
import BarsCore
import Testing
@testable import Bars

@MainActor
@Suite(.serialized)
struct StatusItemIconObservationSignatureTests {
    @Test
    func `store icon observation signature ignores refresh and status metadata churn`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-refresh-metadata")
        defer { controller.releaseStatusItemsForTesting() }

        store.statuses[.opencode] = ProviderStatus(
            indicator: .none,
            description: "initial",
            updatedAt: Date(timeIntervalSince1970: 10))
        let baseline = controller.storeIconObservationSignature()

        store.isRefreshing = true
        store.statuses[.opencode] = ProviderStatus(
            indicator: .none,
            description: "same indicator, newer timestamp",
            updatedAt: Date(timeIntervalSince1970: 20))

        #expect(controller.storeIconObservationSignature() == baseline)
    }

    @Test
    func `custom menu bar layout preserves accessibility without a hover tooltip`() throws {
        let (_, _, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-custom-layout-tooltip",
            menuBarLayout: MenuBarLayout(lines: [[.icon, .providerName]]))
        defer { controller.releaseStatusItemsForTesting() }

        let button = try #require(controller.statusItem.button)
        #expect(button.accessibilityTitle()?.isEmpty == false)
        #expect(button.toolTip == nil)
    }

    @Test
    func `store icon observation signature ignores non visual snapshot churn`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-snapshot-metadata")
        defer { controller.releaseStatusItemsForTesting() }

        let baseline = controller.storeIconObservationSignature()
        #expect(!baseline.contains("icon@example.com"))

        store._setSnapshotForTesting(
            Self.makeSnapshot(
                provider: .opencode,
                email: "rotated-account@example.com",
                updatedAt: Date(timeIntervalSince1970: 200)),
            provider: .opencode)

        let signature = controller.storeIconObservationSignature()

        #expect(signature == baseline)
        #expect(!signature.contains("rotated-account@example.com"))
    }

    @Test
    func `custom account label changes the store icon observation signature`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-custom-account-label",
            menuBarLayout: MenuBarLayout(lines: [[.accountLabel]]))
        defer { controller.releaseStatusItemsForTesting() }

        let baseline = controller.storeIconObservationSignature()
        #expect(!baseline.contains("icon@example.com"))

        store._setSnapshotForTesting(
            Self.makeSnapshot(
                provider: .opencode,
                email: "rotated-account@example.com",
                updatedAt: Date(timeIntervalSince1970: 200)),
            provider: .opencode)

        let signature = controller.storeIconObservationSignature()

        #expect(signature != baseline)
        #expect(!signature.contains("rotated-account@example.com"))
    }

    @Test
    func `hidden custom account label ignores account changes`() {
        let (settings, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-hidden-custom-account-label",
            menuBarLayout: MenuBarLayout(lines: [[.accountLabel]]))
        defer { controller.releaseStatusItemsForTesting() }
        settings.hidePersonalInfo = true
        let baseline = controller.storeIconObservationSignature()

        store._setSnapshotForTesting(
            Self.makeSnapshot(
                provider: .opencode,
                email: "rotated-account@example.com",
                updatedAt: Date(timeIntervalSince1970: 200)),
            provider: .opencode)

        let signature = controller.storeIconObservationSignature()

        #expect(signature == baseline)
        #expect(!signature.contains("rotated-account@example.com"))
    }

    @Test
    func `merged store icon observation signature ignores non primary snapshot churn`() throws {
        let (settings, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-merged-secondary-snapshot")
        defer { controller.releaseStatusItemsForTesting() }

        let registry = ProviderRegistry.shared
        let claudeMetadata = try #require(registry.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: true)
        settings.selectedMenuProvider = .opencode
        store._setSnapshotForTesting(
            Self.makeSnapshot(provider: .claude, email: "claude@example.com"),
            provider: .claude)
        let baseline = controller.storeIconObservationSignature()

        store._setSnapshotForTesting(
            Self.makeSnapshot(
                provider: .claude,
                email: "changed@example.com",
                primaryUsedPercent: 99,
                secondaryUsedPercent: 88,
                updatedAt: Date(timeIntervalSince1970: 300)),
            provider: .claude)

        #expect(controller.storeIconObservationSignature() == baseline)
    }

    @Test
    func `store icon observation signature changes when icon percentages change`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-percent-change")
        defer { controller.releaseStatusItemsForTesting() }

        let baseline = controller.storeIconObservationSignature()

        store._setSnapshotForTesting(
            Self.makeSnapshot(
                provider: .opencode,
                email: "icon@example.com",
                primaryUsedPercent: 42,
                secondaryUsedPercent: 63),
            provider: .opencode)

        #expect(controller.storeIconObservationSignature() != baseline)
    }

    @Test
    func `merged store icon observation signature ignores non primary status changes`() throws {
        let (settings, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-merged-secondary-status")
        defer { controller.releaseStatusItemsForTesting() }

        let registry = ProviderRegistry.shared
        let claudeMetadata = try #require(registry.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: true)
        let baseline = controller.storeIconObservationSignature()

        store.statuses[.claude] = ProviderStatus(
            indicator: .major,
            description: "Claude status issue",
            updatedAt: Date(timeIntervalSince1970: 20))

        #expect(controller.storeIconObservationSignature() == baseline)
    }

    @Test
    func `store icon observation signature ignores status indicator changes`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-status-indicator")
        defer { controller.releaseStatusItemsForTesting() }

        store.statuses[.opencode] = ProviderStatus(
            indicator: .none,
            description: "initial",
            updatedAt: Date(timeIntervalSince1970: 10))
        let baseline = controller.storeIconObservationSignature()

        store.statuses[.opencode] = ProviderStatus(
            indicator: .major,
            description: "major outage",
            updatedAt: Date(timeIntervalSince1970: 20))

        #expect(controller.storeIconObservationSignature() == baseline)
    }

    @Test
    func `store icon observation signature changes when hide critters toggles`() {
        let (settings, _, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-hide-critters")
        defer { controller.releaseStatusItemsForTesting() }

        settings.menuBarHidesCritters = false
        let baseline = controller.storeIconObservationSignature()

        settings.menuBarHidesCritters = true

        #expect(controller.storeIconObservationSignature() != baseline)
    }

    @Test(arguments: [MenuBarLayoutToken.costToday, .costWindow])
    func `custom cost token changes the store icon observation signature`(layoutElement: MenuBarLayoutToken) {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-custom-cost-\(layoutElement)",
            menuBarLayout: MenuBarLayout(lines: [[layoutElement]]))
        defer { controller.releaseStatusItemsForTesting() }

        let baseline = controller.storeIconObservationSignature()

        store._setTokenSnapshotForTesting(
            Self.makeTokenSnapshot(todayCost: 1.25, last30DaysCost: 12.50),
            provider: .opencode)

        #expect(controller.storeIconObservationSignature() != baseline)
    }

    @Test
    func `custom cost layout ignores token fields it does not render`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-custom-cost-irrelevant",
            menuBarLayout: MenuBarLayout(lines: [[.costWindow]]))
        defer { controller.releaseStatusItemsForTesting() }

        store._setTokenSnapshotForTesting(
            Self.makeTokenSnapshot(todayCost: 1.25, last30DaysCost: 12.50, sessionTokens: 100),
            provider: .opencode)
        let baseline = controller.storeIconObservationSignature()

        store._setTokenSnapshotForTesting(
            Self.makeTokenSnapshot(todayCost: 9.99, last30DaysCost: 12.50, sessionTokens: 999),
            provider: .opencode)

        #expect(controller.storeIconObservationSignature() == baseline)
    }

    @Test
    func `token cost publication enters the icon refresh path without a usage change`() async {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-custom-cost-title",
            menuBarLayout: MenuBarLayout(lines: [[.costWindow]]))
        defer { controller.releaseStatusItemsForTesting() }
        controller.updateIcons()
        let baseline = controller.lastObservedStoreIconWorkSignature
        let usageUpdatedAt = store.snapshot(for: .opencode)?.updatedAt
        let usagePrimaryPercent = store.snapshot(for: .opencode)?.primary?.usedPercent

        store._setTokenSnapshotForTesting(
            Self.makeTokenSnapshot(todayCost: 1.25, last30DaysCost: 12.50),
            provider: .opencode)

        for _ in 0..<100 where controller.lastObservedStoreIconWorkSignature == baseline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.snapshot(for: .opencode)?.updatedAt == usageUpdatedAt)
        #expect(store.snapshot(for: .opencode)?.primary?.usedPercent == usagePrimaryPercent)
        #expect(controller.lastObservedStoreIconWorkSignature != baseline)
        #expect(
            controller.menuBarLayoutCosts(provider: .opencode).last30Days ==
                UsageFormatter.currencyString(12.50, currencyCode: "USD"))
    }

    @Test
    func `display settings persist cached widget snapshot`() async {
        let (settings, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-widget-display")
        defer { controller.releaseStatusItemsForTesting() }

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        settings.usageBarsShowUsed = true
        try? await Task.sleep(nanoseconds: 50_000_000)
        await store.widgetSnapshotPersistTask?.value

        #expect(widgetSnapshots.last?.usageBarsShowUsed == true)
        #expect(widgetSnapshots.last?.entries.contains(where: { $0.provider == .opencode }) == true)
    }

    @Test
    func `updateIcons reuses a precomputed store icon signature instead of recomputing it`() {
        let (_, _, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-precomputed-reuse")
        defer { controller.releaseStatusItemsForTesting() }

        let precomputed = "precomputed-store-icon-signature-sentinel"
        controller.updateIcons(precomputedStoreIconSignature: precomputed)

        // A supplied signature must be stored verbatim; if updateIcons recomputed it, the gate would
        // never equal the sentinel value.
        #expect(controller.lastObservedStoreIconWorkSignature == precomputed)
    }

    @Test
    func `updateIcons recomputes the store icon signature when none is provided`() {
        let (_, _, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-recompute-default")
        defer { controller.releaseStatusItemsForTesting() }

        controller.updateIcons()

        #expect(controller.lastObservedStoreIconWorkSignature == controller.storeIconObservationSignature())
    }

    private static func makeSnapshot(
        provider: UsageProvider,
        email: String,
        primaryUsedPercent: Double = 10,
        secondaryUsedPercent: Double = 20,
        updatedAt: Date = Date(timeIntervalSince1970: 100))
        -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: primaryUsedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: secondaryUsedPercent,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: provider.instanceID,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "plus"))
    }

    private static func makeTokenSnapshot(
        todayCost: Double,
        last30DaysCost: Double,
        sessionTokens: Int? = nil,
        now: Date = .init())
        -> CostUsageTokenSnapshot
    {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return CostUsageTokenSnapshot(
            sessionTokens: sessionTokens,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: last30DaysCost,
            daily: [
                CostUsageDailyReport.Entry(
                    date: formatter.string(from: now),
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    costUSD: todayCost,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)
    }

    private func makeController(
        suiteName: String,
        menuBarLayout: MenuBarLayout? = nil,
        provider: UsageProvider = .opencode)
        -> (SettingsStore, UsageStore, StatusItemController)
    {
        let settings = testSettingsStore(suiteName: suiteName)
        settings.statusChecksEnabled = true
        settings.refreshFrequency = .manual
        settings.usageBarsShowUsed = false
        settings.showOptionalCreditsAndExtraUsage = true
        settings.menuBarShowsBrandIconWithPercent = false
        settings.menuBarShowsHighestUsage = false
        settings.mergeIcons = true
        settings.mergedMenuLastSelectedWasOverview = false
        settings.selectedMenuProvider = provider.instanceID
        if let menuBarLayout {
            settings.menuBarShowsBrandIconWithPercent = true
            settings.setMenuBarLayout(menuBarLayout, for: nil)
        }

        let registry = ProviderRegistry.shared
        if provider != .opencode, let codexMeta = registry.metadata[.opencode] {
            settings.setProviderEnabled(provider: .opencode, metadata: codexMeta, enabled: false)
        }
        if provider != .claude, let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        if let providerMeta = registry.metadata[provider] {
            settings.setProviderEnabled(provider: provider, metadata: providerMeta, enabled: true)
        }

        let environmentBase: [String: String] = [:]
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: environmentBase)
        store._setSnapshotForTesting(
            Self.makeSnapshot(provider: provider, email: "icon@example.com"),
            provider: provider)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        return (settings, store, controller)
    }
}
