import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreWidgetSnapshotTests {
    @Test
    func `widget snapshot includes known Claude model scoped weekly quotas only when enabled`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-claude-model-scoped-weekly-rows"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        settings.statusChecksEnabled = false

        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    window: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "claude-weekly-scoped-unknown",
                    title: "Unknown model only",
                    window: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                    usageKnown: false),
                NamedRateWindow(
                    id: "claude-routines",
                    title: "Daily Routines",
                    window: RateWindow(usedPercent: 10, windowMinutes: 1440, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .claude)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        // The setting is opt-in, so untouched defaults must project the standard quota lanes only.
        #expect(settings.claudeModelScopedWeeklyUsageVisible == false)
        store.persistWidgetSnapshot(reason: "claude-model-scoped-weekly-rows-default-test")
        await store.widgetSnapshotPersistTask?.value

        let defaultEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(defaultEntry.usageRows?.map(\.id) == ["primary", "secondary"])

        settings.claudeModelScopedWeeklyUsageVisible = true
        store.persistWidgetSnapshot(reason: "claude-model-scoped-weekly-rows-test")
        await store.widgetSnapshotPersistTask?.value

        let visibleEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(visibleEntry.usageRows?.map(\.id) == ["primary", "secondary", "claude-weekly-scoped-fable"])
        #expect(visibleEntry.usageRows?.map(\.title) == ["Session", "Weekly", "Fable only"])
        #expect(visibleEntry.usageRows?.compactMap(\.percentLeft) == [75, 50, 70])

        settings.claudeModelScopedWeeklyUsageVisible = false
        store.persistWidgetSnapshot(reason: "claude-model-scoped-weekly-rows-disabled-test")
        await store.widgetSnapshotPersistTask?.value

        let hiddenEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(hiddenEntry.usageRows?.map(\.id) == ["primary", "secondary"])
    }

    @Test
    func `widget snapshot drops persisted Claude model scoped weekly rows once the setting is off`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-claude-model-scoped-weekly-fallback"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        settings.statusChecksEnabled = false
        settings.claudeModelScopedWeeklyUsageVisible = true

        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 50, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                tertiary: nil,
                extraRateWindows: [
                    NamedRateWindow(
                        id: "claude-weekly-scoped-fable",
                        title: "Fable only",
                        window: RateWindow(
                            usedPercent: 30,
                            windowMinutes: 10080,
                            resetsAt: nil,
                            resetDescription: nil)),
                ],
                updatedAt: updatedAt),
            provider: .claude)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "claude-model-scoped-weekly-fallback-seed")
        await store.widgetSnapshotPersistTask?.value

        let seededEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(seededEntry.usageRows?.map(\.id) == ["primary", "secondary", "claude-weekly-scoped-fable"])
        let quotaOwnerKey = try #require(seededEntry.quotaOwnerKey)

        // No live Claude snapshot: the projection now falls back to the persisted rows above.
        store.snapshots.removeValue(forKey: .claude)
        settings.claudeModelScopedWeeklyUsageVisible = false
        store.persistWidgetSnapshot(reason: "claude-model-scoped-weekly-fallback-disabled")
        await store.widgetSnapshotPersistTask?.value

        let fallbackEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(fallbackEntry.usageRows?.map(\.id) == ["primary", "secondary"])
        #expect(fallbackEntry.usageRows?.contains { $0.id.hasPrefix("claude-weekly-scoped-") } == false)

        // A persisted entry whose only rows are scoped carve-outs drops out of the projection entirely.
        store.lastQueuedWidgetSnapshot = WidgetSnapshot(
            entries: [
                WidgetSnapshot.ProviderEntry(
                    provider: .claude,
                    updatedAt: updatedAt,
                    primary: nil,
                    secondary: nil,
                    tertiary: nil,
                    usageRows: [
                        WidgetSnapshot.WidgetUsageRowSnapshot(
                            id: "claude-weekly-scoped-fable",
                            title: "Fable only",
                            percentLeft: 70),
                    ],
                    creditsRemaining: nil,
                    codeReviewRemainingPercent: nil,
                    tokenUsage: nil,
                    dailyUsage: [],
                    quotaOwnerKey: quotaOwnerKey),
            ],
            enabledProviders: [.claude],
            generatedAt: updatedAt)

        store.persistWidgetSnapshot(reason: "claude-model-scoped-weekly-fallback-scoped-only")
        await store.widgetSnapshotPersistTask?.value

        #expect(widgetSnapshots.last?.entries.contains { $0.provider == .claude } == false)
    }

    @Test
    func `widget snapshot keeps Claude local cost without quota data`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-claude-local-cost-only"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        settings.statusChecksEnabled = false

        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 4200,
                sessionCostUSD: 1.25,
                last30DaysTokens: 42000,
                last30DaysCostUSD: 12.50,
                daily: [],
                updatedAt: updatedAt),
            provider: .claude)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .opencode,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .opencode)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "claude-local-cost-only-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(entry.updatedAt == updatedAt)
        #expect(entry.primary == nil)
        #expect(entry.secondary == nil)
        #expect(entry.usageRows?.isEmpty == true)
        #expect(entry.tokenUsage?.sessionTokens == 4200)
        #expect(entry.tokenUsage?.last30DaysTokens == 42000)
    }

    @Test
    func `widget snapshot preserves prior Claude quota rows during token only refresh`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-claude-token-only-preserves-quota"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        settings.statusChecksEnabled = false

        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let quotaUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let tokenUpdatedAt = quotaUpdatedAt.addingTimeInterval(60)
        let primary = RateWindow(
            usedPercent: 28,
            windowMinutes: 300,
            resetsAt: quotaUpdatedAt.addingTimeInterval(3600),
            resetDescription: nil)
        let secondary = RateWindow(
            usedPercent: 12,
            windowMinutes: 10080,
            resetsAt: quotaUpdatedAt.addingTimeInterval(86400),
            resetDescription: nil)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: primary,
                secondary: secondary,
                updatedAt: quotaUpdatedAt),
            provider: .claude)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "claude-pre-token-preserves-quota-test")
        await store.widgetSnapshotPersistTask?.value

        let preTokenEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(preTokenEntry.updatedAt == quotaUpdatedAt)
        #expect(preTokenEntry.primary == primary)
        #expect(preTokenEntry.secondary == secondary)
        #expect(preTokenEntry.usageRows?.map(\.id) == ["primary", "secondary"])
        #expect(preTokenEntry.tokenUsage == nil)
        let quotaOwnerKey = try #require(preTokenEntry.quotaOwnerKey)

        store.snapshots.removeValue(forKey: .claude)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 4300,
                sessionCostUSD: 1.50,
                last30DaysTokens: 43000,
                last30DaysCostUSD: 13.50,
                daily: [],
                updatedAt: tokenUpdatedAt),
            provider: .claude)
        store.persistWidgetSnapshot(reason: "claude-token-only-preserves-quota-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(entry.updatedAt == quotaUpdatedAt)
        #expect(entry.primary == primary)
        #expect(entry.secondary == secondary)
        #expect(entry.usageRows?.map(\.id) == ["primary", "secondary"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [72, 88])
        #expect(entry.tokenUsage?.updatedAt == tokenUpdatedAt)
        #expect(entry.tokenUsage?.sessionTokens == 4300)

        store.lastQueuedWidgetSnapshot = WidgetSnapshot(
            entries: [
                WidgetSnapshot.ProviderEntry(
                    provider: .claude,
                    updatedAt: quotaUpdatedAt,
                    primary: primary,
                    secondary: secondary,
                    tertiary: nil,
                    usageRows: [
                        WidgetSnapshot.WidgetUsageRowSnapshot(
                            id: "primary",
                            title: "Session",
                            percentLeft: 72),
                        WidgetSnapshot.WidgetUsageRowSnapshot(
                            id: "secondary",
                            title: "Weekly",
                            percentLeft: 88),
                    ],
                    creditsRemaining: nil,
                    codeReviewRemainingPercent: nil,
                    tokenUsage: nil,
                    dailyUsage: [],
                    quotaOwnerKey: quotaOwnerKey),
            ],
            enabledProviders: [.claude],
            generatedAt: quotaUpdatedAt)
        store.widgetUsagePreservationBlockedProviders.insert(.claude)

        store.persistWidgetSnapshot(reason: "claude-token-only-credential-change-test")
        await store.widgetSnapshotPersistTask?.value

        let blockedEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(blockedEntry.updatedAt == tokenUpdatedAt)
        #expect(blockedEntry.primary == nil)
        #expect(blockedEntry.secondary == nil)
        #expect(blockedEntry.usageRows?.isEmpty == true)

        let placeholder = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)
        store.widgetUsagePreservationBlockedProviders.remove(.claude)
        store.lastQueuedWidgetSnapshot = WidgetSnapshot(
            entries: [
                WidgetSnapshot.ProviderEntry(
                    provider: .claude,
                    updatedAt: quotaUpdatedAt,
                    primary: placeholder,
                    secondary: nil,
                    tertiary: nil,
                    usageRows: [
                        WidgetSnapshot.WidgetUsageRowSnapshot(
                            id: "primary",
                            title: "Session",
                            percentLeft: 100),
                    ],
                    creditsRemaining: nil,
                    codeReviewRemainingPercent: nil,
                    tokenUsage: nil,
                    dailyUsage: [],
                    quotaOwnerKey: quotaOwnerKey),
            ],
            enabledProviders: [.claude],
            generatedAt: quotaUpdatedAt)

        store.persistWidgetSnapshot(reason: "claude-token-only-drops-placeholder-test")
        await store.widgetSnapshotPersistTask?.value

        let filteredEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(filteredEntry.updatedAt == tokenUpdatedAt)
        #expect(filteredEntry.primary == nil)
        #expect(filteredEntry.usageRows?.isEmpty == true)
    }

    @Test
    func `widget snapshot uses Claude enterprise spend limit instead of placeholder quota`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-claude-enterprise-spend-limit"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        settings.statusChecksEnabled = false

        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil,
                    isSyntheticPlaceholder: true),
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 25545.63,
                    limit: 30000,
                    currencyCode: "USD",
                    period: "Monthly cap",
                    updatedAt: updatedAt),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .claude)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "claude-enterprise-spend-limit-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        let row = try #require(entry.usageRows?.first)
        #expect(entry.usageRows?.count == 1)
        #expect(row.id == "extraUsage")
        #expect(row.title == "Monthly cap")
        #expect(abs((row.percentLeft ?? 0) - 14.8479) < 0.0001)
        #expect(row.window?.isSyntheticPlaceholder == false)
    }
}

@MainActor
struct UsageStoreWidgetSnapshotVisibilityTests {
    @Test(arguments: [true, false])
    func `widget snapshot respects extra usage visibility for Devin`(_ showsExtraUsage: Bool) async throws {
        let suite = "UsageStoreWidgetSnapshotTests-devin-extra-usage-\(showsExtraUsage)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        settings.statusChecksEnabled = false
        settings.showOptionalCreditsAndExtraUsage = showsExtraUsage

        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 48,
                    limit: 0,
                    currencyCode: "USD",
                    period: "Extra usage balance",
                    updatedAt: updatedAt),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .devin,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .devin)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "devin-extra-usage-visibility-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .devin })
        #expect((entry.providerCost != nil) == showsExtraUsage)
    }

    @Test
    func `widget snapshot carries token usage age separately from entry freshness`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-token-usage-age"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        settings.statusChecksEnabled = false

        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let entryUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let tokenUpdatedAt = entryUpdatedAt.addingTimeInterval(-45 * 60)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: entryUpdatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .claude)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 4200,
                sessionCostUSD: 1.25,
                last30DaysTokens: 42000,
                last30DaysCostUSD: 12.50,
                daily: [],
                updatedAt: tokenUpdatedAt),
            provider: .claude)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "token-usage-age-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(entry.updatedAt == entryUpdatedAt)
        #expect(entry.tokenUsage?.updatedAt == tokenUpdatedAt)
        #expect(entry.tokenUsage?.isStale(comparedTo: entry.updatedAt) == true)
    }
}

@MainActor
struct UsageStoreWidgetSnapshotAntigravityFamilyTests {}
