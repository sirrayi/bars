import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct WidgetAccountCompatibilityTests {
    private let measuredAt = Date(timeIntervalSince1970: 1_782_000_000)

    @Test
    func `overflow counts follow Claude Swap inventory without expanding publication`() {
        let (claudeSettings, claudeStore) = self.makeStore(provider: .claude)
        claudeSettings.claudeSwapEnabled = true
        claudeStore.claudeSwapAccountSnapshots = self.swapAccounts((1...9).map {
            self.swapRow(number: $0, email: "fixture-\($0)@example.test", isActive: $0 == 9, usedPercent: 20)
        })
        #expect(claudeStore.widgetAccountOverflowCounts() == ["claude": 3])
        #expect(claudeStore.makeWidgetAccountEntries(now: self.measuredAt).count == 6)
        claudeSettings.accountWidgetsEnabled = false
        #expect(claudeStore.widgetAccountOverflowCounts().isEmpty)
    }

    @Test
    func `Claude Swap widget labels do not inherit the app language`() throws {
        let (settings, store) = self.makeStore(provider: .claude)
        settings.claudeSwapEnabled = true
        settings.claudeSwapShowSingleAccount = true
        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 1, email: "fixture@example.com", usedPercent: 20),
        ])
        let english = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            store.makeWidgetAccountEntries(now: self.measuredAt)
        }
        let chinese = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            store.makeWidgetAccountEntries(now: self.measuredAt)
        }
        let expected = try #require(english.first)
        let actual = try #require(chinese.first)
        #expect(actual.id == expected.id)
        #expect(actual.label == expected.label)
    }

    @Test
    func `removing a Claude Swap sibling preserves the remaining pinned widget`() throws {
        let (settings, store) = self.makeStore(provider: .claude)
        settings.claudeSwapEnabled = true
        #expect(!settings.claudeSwapShowSingleAccount)
        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 1, email: "work@example.com", usedPercent: 20),
            self.swapRow(number: 2, email: "personal@example.com", isActive: false, usedPercent: 70),
        ])
        let before = store.makeWidgetAccountEntries(now: self.measuredAt)
        let survivor = try #require(before.first { $0.usage?.primary?.usedPercent == 70 })

        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 2, email: "personal@example.com", usedPercent: 70),
        ])
        let after = store.makeWidgetAccountEntries(now: self.measuredAt.addingTimeInterval(300))
        #expect(after.count == 1)
        #expect(after.first?.id == survivor.id)
        #expect(self.pinnedUsage(id: survivor.id, provider: .claude, accounts: after)?.primary?.usedPercent == 70)
        #expect(after.first?.usage?.updatedAt == survivor.usage?.updatedAt)
        #expect(!settings.claudeSwapShowSingleAccount)
    }

    @Test
    func `reusing a Claude Swap slot cannot inherit another owners pinned widget`() throws {
        let (settings, store) = self.makeStore(provider: .claude)
        settings.claudeSwapEnabled = true
        settings.claudeSwapShowSingleAccount = true
        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 1, email: "original@example.com", usedPercent: 20),
        ])
        let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)

        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 1, email: "replacement@example.com", usedPercent: 80),
        ])
        let replacement = store.makeWidgetAccountEntries(now: self.measuredAt)
        #expect(replacement.count == 1)
        #expect(replacement.first?.id != original.id)
        #expect(self.pinnedUsage(id: original.id, provider: .claude, accounts: replacement) == nil)
        let encoded = try #require(String(data: JSONEncoder().encode(replacement), encoding: .utf8))
        #expect(!encoded.contains("replacement@example.com"))
    }

    @Test
    func `renaming a Claude Swap alias leaves the pinned owner unchanged`() throws {
        let (settings, store) = self.makeStore(provider: .claude)
        settings.claudeSwapEnabled = true
        settings.claudeSwapShowSingleAccount = true
        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 1, email: "work@example.com", alias: "Work", usedPercent: 20),
        ])
        let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)

        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 1, email: "work@example.com", alias: "Renamed", usedPercent: 25),
        ])
        let renamed = store.makeWidgetAccountEntries(now: self.measuredAt)
        #expect(renamed.first?.id == original.id)
        #expect(self.pinnedUsage(id: original.id, provider: .claude, accounts: renamed)?.primary?.usedPercent == 25)
    }

    private func makeStore(provider: UsageProvider) -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(
            suiteName: "WidgetAccountCompatibilityTests",
            userDefaults: InMemoryUserDefaults())
        settings.providerDetectionCompleted = true
        settings.setProviderEnabled(provider: provider, metadata: ProviderDefaults.metadata[provider]!, enabled: true)
        settings.accountWidgetsEnabled = true
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .segmented
        settings.statusChecksEnabled = false
        let store = UsageStore(
            browserDetection: BrowserDetection(homeDirectory: "/synthetic", cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            widgetTimelineReloader: {})
        return (settings, store)
    }

    private func swapRow(
        number: Int,
        email: String,
        alias: String? = nil,
        isActive: Bool = true,
        usedPercent: Double) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: email,
            alias: alias,
            isActive: isActive,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: usedPercent, resetsAt: nil),
            sevenDay: nil,
            usageFetchedAt: self.measuredAt)
    }

    private func swapAccounts(_ rows: [ClaudeSwapAccountRow]) -> [ProviderAccountUsageSnapshot] {
        ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(activeAccountNumber: rows.first?.number, accounts: rows),
            now: self.measuredAt)
    }

    private nonisolated func usage(email: String, usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: usedPercent, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: self.measuredAt,
            identity: ProviderIdentitySnapshot(
                providerID: .opencode,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Pro"))
    }

    private func pinnedUsage(
        id: String,
        provider: UsageProvider,
        accounts: [WidgetSnapshot.AccountEntry]) -> WidgetSnapshot.ProviderEntry?
    {
        WidgetSnapshot(
            entries: [],
            accounts: accounts,
            enabledProviders: [provider.instanceID],
            generatedAt: self.measuredAt)
            .selectingAccount(id, for: provider).entries.first { $0.provider == provider.instanceID }
    }
}
