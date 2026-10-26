import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardWorkdayPaceTests {
    @Test
    func `codex weekly lane hides exhausted pace before first configured workday`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 7,
            hour: 12)))
        let resetsAt = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 14)))
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "Pro")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 100,
                windowMinutes: 10080,
                resetsAt: resetsAt,
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now,
            identity: identity)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "user@example.com", plan: "Pro"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            workDaysPerWeek: 5,
            now: now))

        let weekly = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(weekly.detailLeftText == nil)
        #expect(weekly.detailRightText == nil)
    }
}
