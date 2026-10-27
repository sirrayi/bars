import BarsCore
import Foundation
import SwiftUI
import Testing
@testable import Bars

@MainActor
@Suite(.serialized)
struct PopupLocalizationTests {
    @Test
    func `Claude scoped weekly titles localize only the menu label`() throws {
        let window = RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        for (language, expected) in [
            ("en", "Example Model weekly"),
            ("zh-Hans", "Example Model 每周"),
            ("vi", "Example Model hàng tuần"),
        ] {
            try BarsLocalizationOverride.$appLanguage.withValue(language) {
                for title in ["Example Model only", "Example Model Only", "Example Model ONLY  ", "Example Model"] {
                    let scoped = NamedRateWindow(id: "claude-weekly-scoped-example", title: title, window: window)
                    for showUsed in [true, false] {
                        let model = try Self.makeClaudeMenuCardModel(
                            primaryWindowMinutes: 300, extraRateWindows: [scoped], showUsed: showUsed)
                        let metric = try #require(model.metrics.first { $0.id == scoped.id })
                        #expect(metric.title == expected)
                        #expect(metric.percent == (showUsed ? 25 : 75))
                        #expect(metric.percentStyle == (showUsed ? .used : .left))
                        #expect(scoped.title == title)
                    }
                }
            }
        }
    }

    @Test
    func `Vietnamese weekly and missing version labels are not swapped`() {
        BarsLocalizationOverride.$appLanguage.withValue("vi") {
            #expect(L("Weekly") == "Hàng tuần")
            #expect(L("not detected") == "Không phát hiện được")
        }
    }

    @Test
    func `simplified Chinese derives session quota titles from their duration`() throws {
        try BarsLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            for (windowMinutes, expectedTitle) in [(60, "1 小时"), (300, "5 小时"), (720, "12 小时")] {
                let model = try Self.makeClaudeMenuCardModel(primaryWindowMinutes: windowMinutes)

                #expect(model.metrics.first?.title == expectedTitle)
            }
        }
    }

    @Test
    func `simplified Chinese labels a Claude weekly primary fallback accurately`() throws {
        try BarsLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            let model = try Self.makeClaudeMenuCardModel(primaryWindowMinutes: 7 * 24 * 60)

            #expect(model.metrics.first?.title == "每周")
        }
    }

    @Test
    func `simplified Chinese history selector uses quota duration without changing conversations`() {
        BarsLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let histories = [
                PlanUtilizationSeriesHistory(
                    name: .session,
                    windowMinutes: 300,
                    entries: [PlanUtilizationHistoryEntry(capturedAt: now, usedPercent: 10, resetsAt: nil)]),
                PlanUtilizationSeriesHistory(
                    name: .weekly,
                    windowMinutes: 7 * 24 * 60,
                    entries: [PlanUtilizationHistoryEntry(capturedAt: now, usedPercent: 20, resetsAt: nil)]),
            ]
            let snapshot = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 10,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: now)
            let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                histories: histories,
                provider: .claude,
                snapshot: snapshot)

            #expect(model.visibleSeriesTitles == ["5 小时", "每周"])
            #expect(String(format: L("Session %@"), "abc123") == "会话 abc123")
        }
    }

    @Test
    func `descriptor account labels use selected localization`() throws {
        try BarsLocalizationOverride.$appLanguage.withValue("zh-Hant") {
            let suite = "PopupLocalizationTests-descriptor"
            let settings = try Self.makeSettingsStore(suite: suite)
            let store = UsageStore(
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings,
                startupBehavior: .testing)
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date(),
                    identity: ProviderIdentitySnapshot(
                        providerID: .opencode,
                        accountEmail: "codex@example.com",
                        accountOrganization: nil,
                        loginMethod: "free")),
                provider: .opencode)

            let descriptor = MenuDescriptor.build(
                provider: .opencode,
                store: store,
                settings: settings,
                account: AccountInfo(email: nil, plan: nil),
                updateReady: false,
                includeContextualActions: false)

            let lines = Self.textLines(from: descriptor)

            #expect(lines.contains("帳號: codex@example.com"))
            #expect(lines.contains("方案: Free"))
            #expect(!lines.contains("Account: codex@example.com"))
            #expect(!lines.contains("Plan: Free"))
        }
    }

    @Test
    func `settings labels use selected localization`() {
        BarsLocalizationOverride.$appLanguage.withValue("zh-Hant") {
            #expect(KiroMenuBarDisplayMode.hidden.label == "隱藏")
            #expect(KiroMenuBarDisplayMode.creditsLeft.label == "剩餘額度")
            #expect(L("(System)") == "（系統）")
        }
    }

    private static func makeSettingsStore(suite: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        settings.statusChecksEnabled = false
        return settings
    }

    private static func textLines(from descriptor: MenuDescriptor) -> [String] {
        descriptor.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(text, _) = entry else { return nil }
            return text
        }
    }

    private static func makeClaudeMenuCardModel(
        primaryWindowMinutes: Int,
        extraRateWindows: [NamedRateWindow] = [],
        provider: UsageProvider = .claude,
        showUsed: Bool = false) throws -> UsageMenuCardView.Model
    {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = try #require(ProviderDefaults.metadata[provider] ?? ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: primaryWindowMinutes,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            extraRateWindows: extraRateWindows,
            updatedAt: now)
        return UsageMenuCardView.Model.make(.init(
            provider: provider,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
    }
}
