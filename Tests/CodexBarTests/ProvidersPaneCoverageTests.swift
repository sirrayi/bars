import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct ProvidersPaneCoverageTests {
    @Test
    func `exercises providers pane views`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests")
        let store = Self.makeUsageStore(settings: settings)

        ProvidersPaneTestHarness.exercise(settings: settings, store: store)
    }

    @Test
    func `zai team account add button requires organization and project`() {
        #expect(ProviderSettingsTokenAccountsRowView.isAddDisabled(
            label: "Team",
            token: "token",
            showsTeamModeControls: true,
            teamMode: true,
            teamContext: (organizationID: "", projectID: "proj-test")))
        #expect(ProviderSettingsTokenAccountsRowView.isAddDisabled(
            label: "Team",
            token: "token",
            showsTeamModeControls: true,
            teamMode: true,
            teamContext: (organizationID: "org-test", projectID: "")))
        #expect(!ProviderSettingsTokenAccountsRowView.isAddDisabled(
            label: "Team",
            token: "token",
            showsTeamModeControls: true,
            teamMode: true,
            teamContext: (organizationID: "org-test", projectID: "proj-test")))
        #expect(!ProviderSettingsTokenAccountsRowView.isAddDisabled(
            label: "Personal",
            token: "token",
            showsTeamModeControls: true,
            teamMode: false,
            teamContext: (organizationID: "", projectID: "")))
    }

    @Test
    func `zai team account draft requires complete ids before apply`() {
        let original = ProviderSettingsTokenAccountsRowView.TeamAccountDraft(
            teamMode: false,
            organizationID: "",
            projectID: "")

        #expect(ProviderSettingsTokenAccountsRowView.isTeamDraftApplyDisabled(
            draft: original,
            original: original))
        #expect(ProviderSettingsTokenAccountsRowView.isTeamDraftApplyDisabled(
            draft: ProviderSettingsTokenAccountsRowView.TeamAccountDraft(
                teamMode: true,
                organizationID: "org-test",
                projectID: ""),
            original: original))
        #expect(!ProviderSettingsTokenAccountsRowView.isTeamDraftApplyDisabled(
            draft: ProviderSettingsTokenAccountsRowView.TeamAccountDraft(
                teamMode: true,
                organizationID: "org-test",
                projectID: "proj-test"),
            original: original))
        #expect(!ProviderSettingsTokenAccountsRowView.isTeamDraftApplyDisabled(
            draft: ProviderSettingsTokenAccountsRowView.TeamAccountDraft(
                teamMode: false,
                organizationID: "",
                projectID: ""),
            original: ProviderSettingsTokenAccountsRowView.TeamAccountDraft(
                teamMode: true,
                organizationID: "org-test",
                projectID: "proj-test")))
    }

    @Test
    func `provider reordering is inert while alphabetical sorting is enabled`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-sorted-reorder")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)
        let original = settings.orderedProviders()

        settings.providersSortedAlphabetically = true
        pane._test_moveProviders(fromOffsets: IndexSet(integer: 0), toOffset: original.count)
        #expect(settings.orderedProviders() == original)

        settings.providersSortedAlphabetically = false
        pane._test_moveProviders(fromOffsets: IndexSet(integer: 0), toOffset: original.count)
        #expect(settings.orderedProviders().last == original.first)
    }

    @Test
    @MainActor
    func `settings pane titles cover app panes and providers`() {
        #expect(SettingsPane.general.title == L("tab_general"))
        #expect(SettingsPane.about.title == L("tab_about"))
        #expect(!SettingsPane.provider(.devin).title.isEmpty)
        #expect(SettingsPane.provider(.devin) != SettingsPane.provider(.claude))
    }

    @Test
    func `claude provider preview follows daily routines visibility`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-claude-routines-preview")
        let store = Self.makeUsageStore(settings: settings)
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 30,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: nil),
                extraRateWindows: [
                    NamedRateWindow(
                        id: "claude-weekly-scoped-fable",
                        title: "Fable only",
                        window: RateWindow(
                            usedPercent: 30,
                            windowMinutes: 10080,
                            resetsAt: now.addingTimeInterval(3600),
                            resetDescription: nil)),
                    NamedRateWindow(
                        id: "claude-routines",
                        title: "Daily Routines",
                        window: RateWindow(
                            usedPercent: 40,
                            windowMinutes: 10080,
                            resetsAt: now.addingTimeInterval(7200),
                            resetDescription: nil)),
                ],
                updatedAt: now),
            provider: .claude)
        let pane = ProvidersPane(settings: settings, store: store)

        #expect(pane._test_menuCardModel(for: .claude).metrics.contains { $0.id == "claude-routines" })

        settings.setUsageItemVisible(false, itemID: .metric("claude-routines"), for: .claude)
        let hiddenModel = pane._test_menuCardModel(for: .claude)
        #expect(!hiddenModel.metrics.contains { $0.id == "claude-routines" })
        #expect(hiddenModel.metrics.contains { $0.id == "claude-weekly-scoped-fable" })
    }

    @Test
    func `provider detail plan row keeps plan label for non open router`() {
        Self.withEnglishLocalization {
            let row = ProviderDetailView.planRow(provider: .devin, planText: "Pro")

            #expect(row?.label == "Plan")
            #expect(row?.value == "Pro")
        }
    }

    @Test
    func `provider detail renders metric status without progress`() {
        let metric = UsageMenuCardView.Model.Metric(
            id: "fixture",
            title: "Example quota",
            percent: 0,
            percentStyle: .left,
            statusText: "Unavailable",
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false)

        #expect(ProviderDetailView.metricInlinePresentation(metric) == .status("Unavailable"))
    }

    @Test
    func `provider detail renders ordinary metric progress`() {
        let metric = UsageMenuCardView.Model.Metric(
            id: "fixture",
            title: "Example quota",
            percent: 50,
            percentStyle: .left,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false)

        #expect(ProviderDetailView.metricInlinePresentation(metric) == .progress)
    }

    @Test
    func `opencode manual cookie source hides cached browser trailing text`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-opencode-manual")
        let store = Self.makeUsageStore(settings: settings)
        settings.opencodeCookieSource = .manual
        CookieHeaderCache.store(provider: .opencode, cookieHeader: "auth=cache", sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: .opencode) }

        let pane = ProvidersPane(settings: settings, store: store)
        let picker = pane._test_settingsPickers(for: .opencode).first { $0.id == "opencode-cookie-source" }

        #expect(picker?.dynamicSubtitle?() == "Paste a Cookie header captured from the billing page.")
        #expect(picker?.trailingText?() == nil)
        #expect(picker?.trailingActions.first?.isVisible?() == false)
    }

    @Test
    func `opencode go manual cookie source hides cached browser trailing text`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-opencodego-manual")
        let store = Self.makeUsageStore(settings: settings)
        settings.opencodegoCookieSource = .manual
        CookieHeaderCache.store(provider: .opencodego, cookieHeader: "auth=cache", sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: .opencodego) }

        let pane = ProvidersPane(settings: settings, store: store)
        let picker = pane._test_settingsPickers(for: .opencodego).first { $0.id == "opencodego-cookie-source" }

        #expect(picker?.dynamicSubtitle?() == "Paste a Cookie header captured from the billing page.")
        #expect(picker?.trailingText?() == nil)
        #expect(picker?.trailingActions.first?.isVisible?() == false)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            claudeCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
    }

    private static func withEnglishLocalization(perform body: () -> Void) {
        CodexBarLocalizationOverride.$appLanguage.withValue("en", operation: body)
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let auth = [
            "tokens": [
                "accessToken": "access-token",
                "refreshToken": "refresh-token",
                "idToken": Self.fakeJWT(email: email, plan: plan),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}
