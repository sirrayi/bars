import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct UsageStoreHighestUsageTests {
    @Test
    func `selects highest usage among enabled providers`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-selects"))
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let claudeSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(claudeSnapshot, provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 60)

        let overviewHighest = store.providerWithHighestUsage(candidateProviders: [.codex])
        #expect(overviewHighest?.provider == .codex)
        #expect(overviewHighest?.usedPercent == 25)
        #expect(store.providerWithHighestUsage(candidateProviders: []) == nil)
    }

    @Test
    func `automatic highest usage ignores pace unsupported OpenCode lane`() {
        let settings = testSettingsStore(
            suiteName: "UsageStoreHighestUsageTests-opencode-lane-pace",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }))
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .claude)
        settings.setMenuBarMetricPreference(.automatic, for: .opencode)

        let registry = ProviderRegistry.shared
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }
        if let opencodeMeta = registry.metadata[.opencode] {
            settings.setProviderEnabled(provider: .opencode, metadata: opencodeMeta, enabled: true)
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(
                homeDirectory: "/synthetic-opencode-lane-pace",
                cacheTTL: 0,
                now: { now },
                fileExists: { _ in false },
                directoryContents: { _ in [] },
                applicationURLs: { _ in [] },
                profileAccessIssue: { _ in nil }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        let claude = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 99,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(1800),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        let opencode = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 99.5,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(1800),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 95,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: now)

        store._setSnapshotForTesting(claude, provider: .claude)
        store._setSnapshotForTesting(opencode, provider: .opencode)

        let highest = store.providerWithHighestUsage(now: now)
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 99)
    }

    @Test
    func `skips fully used providers`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-skips"))
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let claudeSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(claudeSnapshot, provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 80)
    }
}

extension UsageStoreHighestUsageTests {
    private func antigravityQuotaSummarySnapshot(
        geminiSessionUsed: Double,
        geminiWeeklyUsed: Double,
        otherSessionUsed: Double,
        otherWeeklyUsed: Double) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Session",
                    window: RateWindow(
                        usedPercent: geminiSessionUsed,
                        windowMinutes: 5 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Weekly",
                    window: RateWindow(
                        usedPercent: geminiWeeklyUsed,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude + GPT Session",
                    window: RateWindow(
                        usedPercent: otherSessionUsed,
                        windowMinutes: 5 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude + GPT Weekly",
                    window: RateWindow(
                        usedPercent: otherWeeklyUsed,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: Date())
    }
}

extension UsageStoreHighestUsageTests {}
