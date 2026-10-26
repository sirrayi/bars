import AppKit
import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

/// Coverage for the compact multi-account layout on the token-account and Codex
/// paths (the claude-swap path is covered by StatusMenuClaudeSwapCompactTests).
@MainActor
final class StatusMenuCompactAccountLayoutTests: XCTestCase {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
    }

    private func snapshot(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: nil)
    }

    func test_codexAccountProjectionMapsActiveHealthAndIdentity() {
        let accounts = (1...4).map { index in
            CodexVisibleAccount(
                id: "account-\(index)",
                email: "codex\(index)@example.com",
                // account-4: stored account without live auth → "Missing auth" health.
                storedAccountID: index == 4 ? UUID() : nil,
                selectionSource: .liveSystem,
                isActive: index == 2,
                isLive: index != 4,
                canReauthenticate: false,
                canRemove: false)
        }
        let snapshots = accounts.prefix(3).map { account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(usedPercent: 50),
                error: nil,
                sourceLabel: "test")
        }
        let display = CodexAccountMenuDisplay(
            accounts: accounts,
            snapshots: Array(snapshots),
            activeVisibleAccountID: "account-2",
            layout: .stacked)

        let projected = StatusItemController.projectedCodexAccounts(display: display)

        XCTAssertEqual(projected.map(\ProviderAccountUsageSnapshot.id.opaqueID), [
            "account-1", "account-2", "account-3", "account-4",
        ])
        XCTAssertEqual(projected.map(\ProviderAccountUsageSnapshot.isActive), [false, true, false, false])
        XCTAssertEqual(projected[0].id.source, "codex-account")
        XCTAssertEqual(projected[0].displayLabel, "codex1@example.com")
        // account-4 has no snapshot: unavailable health surfaces as an error row.
        XCTAssertNil(projected[3].snapshot)
        XCTAssertNotNil(projected[3].error)
        XCTAssertNil(projected[0].error)
    }

    func test_codexAccountProjectionIncludesMonthlyCreditInPlanningSnapshot() {
        let account = CodexVisibleAccount(
            id: "biz-1",
            email: "biz@example.com",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: false,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        let now = Date()
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 95,
                limit: 100,
                remainingPercent: 5,
                resetsAt: nil,
                updatedAt: now))
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "biz@example.com",
                accountOrganization: "Team",
                loginMethod: "business"))
        let display = CodexAccountMenuDisplay(
            accounts: [account],
            snapshots: [
                CodexAccountUsageSnapshot(
                    account: account,
                    snapshot: snapshot,
                    error: nil,
                    sourceLabel: "test",
                    credits: credits),
            ],
            activeVisibleAccountID: nil,
            layout: .stacked)

        let shown = StatusItemController.projectedCodexAccounts(
            display: display,
            includeOptionalCredits: true)
        XCTAssertEqual(AccountMenuLayoutPlanner.headroomPercent(for: shown[0]), 5)
        XCTAssertEqual(shown[0].snapshot?.tertiary?.usedPercent, 95)

        let hidden = StatusItemController.projectedCodexAccounts(
            display: display,
            includeOptionalCredits: false)
        XCTAssertNil(AccountMenuLayoutPlanner.headroomPercent(for: hidden[0]))
        XCTAssertNil(hidden[0].snapshot?.tertiary)
    }
}
