import BarsCore
import Foundation
import Observation
import SwiftUI
import Testing
@testable import Bars

@MainActor
struct ProviderUsageItemVisibilityTests {
    @Test
    func `globally gated quota rows retain their explanation when unavailable`() {
        for (provider, optionalIDs) in [
            (UsageProvider.claude, ["claude-routines"]),
        ] {
            let model = Self.model(
                provider: provider,
                metricIDs: ["primary", "secondary"] + optionalIDs)
            let items = model.usageItemDescriptors
            #expect(items.filter(\.requiresOptionalUsage).map(\.id) == optionalIDs.map(ProviderUsageItemID.metric))
            let unavailable = Self.model(provider: provider, metricIDs: ["primary", "secondary"])
                .usageItemDescriptors(includingHidden: Set(optionalIDs.map(ProviderUsageItemID.metric)))
            #expect(unavailable.filter(\.requiresOptionalUsage).count == optionalIDs.count)
            #expect(!ProviderUsageItemID.subscription.requiresOptionalUsage(for: provider))
        }
    }

    @Test
    func `claude independently selects resets extra usage and subscription without losing quota notes`() {
        var model = Self.model(provider: .claude, metricIDs: ["primary", "secondary"], showsResetCredits: true)
        model.providerCost = .init(title: "Extra usage", percentUsed: 10, spendLine: "$1 / $10", percentLine: nil)
        model.subscriptionNotes = ["Plan renews: Nov 5, 2026"]
        model.usageNotes = ["Usage estimate", "Plan renews: Nov 5, 2026"]
        let items = model.usageItemDescriptors
        #expect(items.contains { $0.id == .claudeResetCredits && !$0.requiresOptionalUsage })
        #expect(items.contains { $0.id == .claudeExtraUsage && $0.requiresOptionalUsage })
        #expect(items.contains { $0.id == .subscription && !$0.requiresOptionalUsage })
        #expect(model.quotaSubscriptionNotes == ["Plan renews: Nov 5, 2026"])
        #expect(model.supplementalUsageNotes == ["Usage estimate"])

        let hidden = model.applyingUsageItemVisibility(hiddenItemIDs: [.claudeExtraUsage, .subscription])
        #expect(hidden.providerCost == nil)
        #expect(hidden.limitResetCredits != nil)
        #expect(hidden.metrics.count == 2)
        #expect(hidden.subscriptionNotes.isEmpty)
        #expect(hidden.usageNotes == ["Usage estimate"])
        #expect(model.applyingUsageItemVisibility(hiddenItemIDs: [.claudeResetCredits]).limitResetCredits == nil)
        model.providerCost = .init(title: "API spend", percentUsed: nil, spendLine: "$10", percentLine: nil)
        #expect(model.applyingUsageItemVisibility(hiddenItemIDs: [.claudeExtraUsage]).providerCost != nil)
    }

    @Test
    func `new visibility controls retain recognizable unavailable labels`() {
        #expect(ProviderUsageItemID.claudeResetCredits.unreportedTitle(for: .claude) == "Limit Reset Credits")
        #expect(ProviderUsageItemID.claudeExtraUsage.unreportedTitle(for: .claude) == "Extra usage")
        #expect(ProviderUsageItemID.subscription.unreportedTitle(for: .opencode) == "Plan renewal / expiry")
    }

    @Test
    func `cosmetic edits preserve account caches spend ownership and synced refresh state`() throws {
        let defaults = InMemoryUserDefaults()
        let configStore = testConfigStore(suiteName: "visibility-ownership-\(UUID().uuidString)")
        try configStore.save(BarsConfig(providers: UsageProvider.allCases.map {
            ProviderConfig(id: $0.instanceID, enabled: $0 == .claude)
        }))
        let settings = Self.settings(defaults: defaults, configStore: configStore)
        defer { settings.configFileWatcher?.stop() }
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        settings.addTokenAccount(provider: .claude, label: "Synthetic", token: "fixture-original")
        let account = try #require(settings.tokenAccounts(for: .claude).first)
        let home = configStore.fileURL.deletingLastPathComponent().path
        let environment = ["HOME": home]
        let store = UsageStore(
            browserDetection: BrowserDetection(homeDirectory: home, cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        defer { store.stopSharedSpendDashboardPublication() }
        let key = store.tokenAccountSnapshotCacheKey(provider: .claude, account: account)
        store.accountSnapshots[.claude] = [TokenAccountUsageSnapshot(
            account: account,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            error: nil,
            sourceLabel: "synthetic",
            cacheKey: key)]
        let ownership = SpendDashboardSource.configuration(settings: settings, store: store).sourceOwnershipFingerprints
        #expect(!ownership.isEmpty)
        let fetchRevision = settings.providerConfigRevision(for: .claude)
        let backgroundRevision = settings.backgroundWorkSettingsRevision

        settings.setUsageItemVisible(false, itemID: .metric("primary"), for: .claude)
        #expect(store.tokenAccountSnapshotCacheKey(provider: .claude, account: account) == key)
        #expect(store.validTokenAccountSnapshots(provider: .claude, accounts: [account]).count == 1)
        #expect(SpendDashboardSource.configuration(settings: settings, store: store)
            .sourceOwnershipFingerprints == ownership)

        var incoming = settings.configSnapshot
        let index = try #require(incoming.providers.firstIndex { $0.id == .claude })
        incoming.providers[index].hiddenUsageItemIDs = ["metric:secondary"]
        incoming.providers[index].accentColor = "#123456"
        settings.applyExternalConfig(incoming, reason: "synthetic-cosmetic-sync", affectsBackgroundWork: false)
        #expect(settings.providerConfigRevision(for: .claude) == fetchRevision)
        #expect(settings.backgroundWorkSettingsRevision == backgroundRevision)
        #expect(store.tokenAccountSnapshotCacheKey(provider: .claude, account: account) == key)
        #expect(store.validTokenAccountSnapshots(provider: .claude, accounts: [account]).count == 1)
        #expect(SpendDashboardSource.configuration(settings: settings, store: store)
            .sourceOwnershipFingerprints == ownership)

        settings.updateTokenAccount(provider: .claude, accountID: account.id, token: "fixture-rotated")
        let rotated = try #require(settings.tokenAccounts(for: .claude).first)
        #expect(store.tokenAccountSnapshotCacheKey(provider: .claude, account: rotated) != key)
        #expect(store.validTokenAccountSnapshots(provider: .claude, accounts: [rotated]).isEmpty)
        #expect(SpendDashboardSource.configuration(settings: settings, store: store)
            .sourceOwnershipFingerprints != ownership)
    }

    @Test
    func `changing usage item visibility leaves the provider refresh revision untouched`() {
        let settings = Self.settings(
            defaults: InMemoryUserDefaults(),
            configStore: testConfigStore(
                suiteName: "ProviderUsageItemVisibilityTests-refresh-revision-\(UUID().uuidString)"))
        let provider = UsageProvider.opencode
        let before = settings.providerConfigRevision(for: provider)

        settings.setUsageItemVisible(false, itemID: .metric("primary"), for: provider)

        #expect(settings.hiddenUsageItemIDs(for: provider) == [.metric("primary")])
        #expect(settings.providerConfigRevision(for: provider) == before)

        settings.restoreDefaultUsageItemVisibility(for: provider)

        #expect(settings.hiddenUsageItemIDs(for: provider).isEmpty)
        #expect(settings.providerConfigRevision(for: provider) == before)
    }

    @Test
    func `visibility changes notify menus while preserving other providers and fetch state`() {
        let settings = Self.settings(
            defaults: InMemoryUserDefaults(),
            configStore: testConfigStore(suiteName: "usage-item-observation-\(UUID().uuidString)"))
        let changed = LockIsolated(false)
        let fetchRevision = settings.providerConfigRevision(for: .opencode)
        let backgroundRevision = settings.backgroundWorkSettingsRevision
        withObservationTracking {
            _ = settings.menuObservationToken
        } onChange: {
            changed.setValue(true)
        }

        settings.setUsageItemVisible(false, itemID: .metric("primary"), for: .opencode)

        #expect(changed.value)
        #expect(settings.isUsageItemVisible(.metric("primary"), for: .claude))
        #expect(settings.providerConfigRevision(for: .opencode) == fetchRevision)
        #expect(settings.backgroundWorkSettingsRevision == backgroundRevision)
    }

    @Test(arguments: [true, false], [true, false])
    func `pre split config loads and independent choices persist without losing saved data`(
        hasHiddenItems: Bool, optionalUsageEnabled: Bool) throws
    {
        let configStore = testConfigStore(suiteName: "visibility-upgrade-\(UUID().uuidString)")
        let hiddenField = hasHiddenItems
            ? #", "hiddenUsageItemIDs": ["metric:secondary", "future:item"]"# : ""
        let legacyJSON = """
        {"version":1,"providers":[
          {"id":"claude","enabled":true,"source":"web","accentColor":"#123456"\(hiddenField)},
          {"id":"codex","enabled":false,"hiddenUsageItemIDs":["section:credits"]}
        ]}
        """
        try FileManager.default.createDirectory(
            at: configStore.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacyJSON.utf8).write(to: configStore.fileURL)
        let defaults = InMemoryUserDefaults(values: [
            "showOptionalCreditsAndExtraUsage": optionalUsageEnabled,
            "bars.legacySecretsMigrationCompleted": true,
        ])
        let settings = Self.settings(defaults: defaults, configStore: configStore)
        defer { settings.configFileWatcher?.stop() }
        let oldIDs: Set<ProviderUsageItemID> = hasHiddenItems
            ? [.metric("secondary"), .init(rawValue: "future:item")] : []
        #expect(settings.showOptionalCreditsAndExtraUsage == optionalUsageEnabled)
        let migratedIDs = optionalUsageEnabled ? oldIDs : oldIDs.union([.claudeResetCredits])
        #expect(settings.hiddenUsageItemIDs(for: .claude) == migratedIDs)
        #expect(settings.providerConfig(for: .claude)?.claudeResetCreditsVisibilityMigrated == true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalCodex = try encoder.encode(settings.providerConfig(for: .opencode))
        let fetchRevision = settings.providerConfigRevision(for: .claude)
        let backgroundRevision = settings.backgroundWorkSettingsRevision

        settings.setUsageItemVisible(false, itemID: .claudeResetCredits, for: .claude)
        settings.setUsageItemVisible(false, itemID: .subscription, for: .claude)
        let expected = oldIDs.union([.claudeResetCredits, .subscription])
        #expect(settings.hiddenUsageItemIDs(for: .claude) == expected)
        #expect(settings.providerConfigRevision(for: .claude) == fetchRevision)
        #expect(settings.backgroundWorkSettingsRevision == backgroundRevision)
        settings.configFileWatcher?.stop()

        let reloaded = Self.settings(defaults: defaults, configStore: configStore)
        defer { reloaded.configFileWatcher?.stop() }
        #expect(reloaded.hiddenUsageItemIDs(for: .claude) == expected)
        #expect(reloaded.showOptionalCreditsAndExtraUsage == optionalUsageEnabled)
        #expect(reloaded.providerConfig(for: .claude)?.source == .web)
        #expect(reloaded.providerConfig(for: .claude)?.enabled == true)
        #expect(reloaded.providerConfig(for: .claude)?.accentColor == "#123456")
        #expect(try encoder.encode(reloaded.providerConfig(for: .opencode)) == originalCodex)
        reloaded.setUsageItemVisible(true, itemID: .claudeResetCredits, for: .claude)
        #expect(reloaded.hiddenUsageItemIDs(for: .claude) == oldIDs.union([.subscription]))
        #expect(try configStore.load()?.providerConfig(for: .claude)?.hiddenUsageItemIDs ==
            oldIDs.union([.subscription]).map(\.rawValue).sorted())
        reloaded.configFileWatcher?.stop()
        defaults.set(false, forKey: "showOptionalCreditsAndExtraUsage")
        let restarted = Self.settings(defaults: defaults, configStore: configStore)
        defer { restarted.configFileWatcher?.stop() }
        #expect(restarted.isUsageItemVisible(.claudeResetCredits, for: .claude))
        #expect(restarted.hiddenUsageItemIDs(for: .claude) == oldIDs.union([.subscription]))
        #expect(restarted.providerConfig(for: .claude)?.claudeResetCreditsVisibilityMigrated == true)
    }

    @Test
    func `reset migration marker preserves synced choices and does not change fetch ownership`() throws {
        var sender = ProviderConfig(id: .claude, hiddenUsageItemIDs: ["metric:secondary"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalIdentity = try encoder.encode(sender.fetchIdentityConfig)
        sender.claudeResetCreditsVisibilityMigrated = true
        #expect(try encoder.encode(sender.fetchIdentityConfig) == originalIdentity)
        let payload = try JSONDecoder().decode(ProviderIntentPayload.self, from: encoder.encode(
            ProviderIntentPayload(config: sender)))
        let received = try payload.applying(
            to: ProviderConfig(id: .claude),
            secretFields: [:],
            canEnable: { _, _ in true })
        #expect(received.claudeResetCreditsVisibilityMigrated == true)
        #expect(received.hiddenUsageItemIDs == ["metric:secondary"])

        let oldPayload = try JSONDecoder().decode(ProviderIntentPayload.self, from: Data(
            #"{"schemaVersion":1,"provider":"claude","hiddenUsageItemIDs":[]}"#.utf8))
        #expect(oldPayload.claudeResetCreditsVisibilityMigrated == nil)
        let olderSync = try oldPayload.applying(to: received, secretFields: [:], canEnable: { _, _ in true })
        #expect(olderSync.claudeResetCreditsVisibilityMigrated == true)
        #expect(olderSync.hiddenUsageItemIDs == [])

        let defaults = InMemoryUserDefaults(values: ["showOptionalCreditsAndExtraUsage": false])
        let configStore = testConfigStore(suiteName: "visibility-migration-sync-\(UUID().uuidString)")
        try configStore.save(BarsConfig(providers: [received]))
        let settings = Self.settings(defaults: defaults, configStore: configStore)
        defer { settings.configFileWatcher?.stop() }
        #expect(settings.isUsageItemVisible(.claudeResetCredits, for: .claude))
        #expect(settings.hiddenUsageItemIDs(for: .claude) == [.metric("secondary")])
    }

    @Test
    func `fresh defaults retain independent reset visibility after the global switch is disabled`() {
        let defaults = InMemoryUserDefaults()
        let configStore = testConfigStore(suiteName: "visibility-new-install-\(UUID().uuidString)")
        let settings = Self.settings(defaults: defaults, configStore: configStore)
        defer { settings.configFileWatcher?.stop() }
        #expect(settings.isUsageItemVisible(.claudeResetCredits, for: .claude))
        settings.showOptionalCreditsAndExtraUsage = false
        let restarted = Self.settings(defaults: defaults, configStore: configStore)
        defer { restarted.configFileWatcher?.stop() }
        #expect(restarted.isUsageItemVisible(.claudeResetCredits, for: .claude))
        #expect(restarted.providerConfig(for: .claude)?.claudeResetCreditsVisibilityMigrated == true)
    }

    static func settings(
        defaults: InMemoryUserDefaults,
        configStore: BarsConfigStore) -> SettingsStore
    {
        // Temporary config alone does not isolate migration from real legacy credentials.
        SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            claudeCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            tokenAccountStore: InMemoryTokenAccountStore(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }),
            performInitialProviderDetection: false)
    }

    private static func model(
        provider: UsageProvider,
        metricIDs: [String],
        showsCredits: Bool = false,
        showsResetCredits: Bool = false,
        detailSections: [ProviderDetailSection] = [],
        detailRawTitles: [String?]? = nil,
        monthlyIsSyntheticCreditLane: Bool = false) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model(
            provider: provider,
            providerName: provider.rawValue,
            email: "user@example.com",
            subtitleText: "Updated just now",
            subtitleStyle: .info,
            planText: nil,
            metrics: metricIDs.map { id in
                .init(
                    id: id,
                    title: id == "secondary" ? "Weekly" : id,
                    percent: 25,
                    percentStyle: .used,
                    resetText: nil,
                    detailText: nil,
                    detailLeftText: nil,
                    detailRightText: nil,
                    pacePercent: nil,
                    paceOnTop: true,
                    isSyntheticCreditLane: id == "monthly" && monthlyIsSyntheticCreditLane)
            },
            usageNotes: [],
            providerDetails: detailSections,
            providerDetailRawTitles: detailRawTitles ?? detailSections.map(\.title),
            inlineUsageDashboard: nil,
            creditsText: showsCredits ? "$12.34 remaining" : nil,
            creditsRemaining: showsCredits ? 12.34 : nil,
            creditsProgressPercent: showsCredits ? 50 : nil,
            creditsScaleText: showsCredits ? "$25" : nil,
            creditsHintText: showsCredits ? "Available balance" : nil,
            creditsHintCopyText: showsCredits ? "Available balance" : nil,
            limitResetCredits: showsResetCredits
                ? LimitResetCreditsPresentation(
                    text: "1 available",
                    items: [.init(expiryText: "Expires tomorrow", compactExpiryText: "tomorrow")])
                : nil,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .blue)
    }
}
