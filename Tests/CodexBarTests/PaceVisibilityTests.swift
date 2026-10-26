import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct PaceVisibilityTests {
    /// Claude session window that is well ahead of the sustainable rate, so the
    /// pace stripe and the forecast text both have something to render.
    private static func offPaceInput(
        now: Date,
        metadata: ProviderMetadata,
        paceVisible: Bool,
        hidePersonalInfo: Bool = false) -> UsageMenuCardView.Model.Input
    {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 60,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 70,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(5 * 86400),
                resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "claude@example.com",
                accountOrganization: nil,
                loginMethod: "Max"))
        return .init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "claude@example.com", plan: "Max"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: hidePersonalInfo,
            paceVisible: paceVisible,
            now: now)
    }

    @Test
    func `pace stripe and text render when pace is visible`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(
            Self.offPaceInput(now: now, metadata: metadata, paceVisible: true))

        let primary = try #require(model.metrics.first { $0.id == "primary" })
        #expect(primary.pacePercent != nil)
        #expect(primary.detailLeftText != nil)
    }

    @Test
    func `hiding pace clears the stripe and the forecast text`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(
            Self.offPaceInput(now: now, metadata: metadata, paceVisible: false))

        #expect(!model.metrics.isEmpty)
        for metric in model.metrics {
            #expect(metric.pacePercent == nil)
            #expect(metric.detailLeftText == nil)
            #expect(metric.detailRightText == nil)
            #expect(metric.sessionEquivalentDetail == nil)
        }
    }

    /// The primary lane is built from `PrimaryMetricPresentation` rather than a
    /// `PaceDetail`, so it takes a different path than the secondary lane.
    @Test
    func `hiding pace clears the primary metric specifically`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(
            Self.offPaceInput(now: now, metadata: metadata, paceVisible: false))

        let primary = try #require(model.metrics.first { $0.id == "primary" })
        #expect(primary.pacePercent == nil)
        #expect(primary.detailLeftText == nil)
        #expect(primary.detailRightText == nil)
    }

    /// Guards the interaction with `redactedMetrics`, which rebuilds every
    /// metric field by field when personal info is hidden.
    @Test
    func `hiding pace also applies when personal info is hidden`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(Self.offPaceInput(
            now: now,
            metadata: metadata,
            paceVisible: false,
            hidePersonalInfo: true))

        let primary = try #require(model.metrics.first { $0.id == "primary" })
        #expect(primary.pacePercent == nil)
        #expect(primary.detailLeftText == nil)
    }

    /// Quota and workday decorations are unrelated to pace and must survive.
    @Test
    func `hiding pace keeps quota warning markers`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        var input = Self.offPaceInput(now: now, metadata: metadata, paceVisible: false)
        input = UsageMenuCardView.Model.Input(
            provider: .claude,
            metadata: metadata,
            snapshot: input.snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: input.account,
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            quotaWarningThresholds: [.session: [50, 20]],
            paceVisible: false,
            now: now)
        let model = UsageMenuCardView.Model.make(input)

        let primary = try #require(model.metrics.first { $0.id == "primary" })
        #expect(primary.pacePercent == nil)
        // usageBarsShowUsed: true mirrors thresholds, so 50/20 render at 50/80.
        #expect(primary.warningMarkerPercents == [50, 80])
    }
}

@MainActor
struct PaceVisibilitySettingsTests {
    @Test
    func `defaults pace to visible and seeds the raw key`() throws {
        let suite = "SettingsStoreTests-pace-visible-defaults"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore)

        #expect(store.paceVisible == true)
        #expect(defaults.object(forKey: "paceVisible") as? Bool == true)

        store.paceVisible = false
        #expect(store.paceVisible == false)
        #expect(defaults.object(forKey: "paceVisible") as? Bool == false)
    }
}
