import Foundation
import Testing
@testable import BarsCore

struct ClaudeSwapAccountAliasProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_782_000_000)

    @Test
    func `keeps unique emails as email only even when organization names are present`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "work@example.com", organizationName: "Sendbird"),
                self.row(number: 2, email: "personal@example.com", organizationName: "Acme", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == ["personal@example.com", "work@example.com"])
        #expect(snapshots.map { $0.snapshot?.identity?.accountOrganization } == [nil, nil])
        #expect(snapshots.map { $0.snapshot?.identity?.accountEmail } == [
            "personal@example.com",
            "work@example.com",
        ])
        #expect(snapshots.map(\.id.opaqueID) == ["2", "1"])
    }

    @Test
    func `disambiguates shared emails with organization name or slot ordinal`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird"),
                self.row(number: 4, email: "shared@example.com", organizationName: "", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == [
            "shared@example.com · Account 4",
            "shared@example.com · Sendbird",
        ])
        #expect(snapshots.first?.id == ProviderAccountIdentity(source: "claude-swap", opaqueID: "4"))
        #expect(snapshots.last?.id == ProviderAccountIdentity(source: "claude-swap", opaqueID: "1"))
        #expect(snapshots.first?.snapshot?.identity?.accountOrganization == nil)
        #expect(snapshots.last?.snapshot?.identity?.accountOrganization == nil)
        #expect(snapshots.first?.snapshot?.identity?.accountEmail == "shared@example.com")
    }

    @Test
    func `disambiguates shared emails that differ only by case`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "Shared@example.com", organizationName: "Sendbird"),
                self.row(number: 2, email: "shared@example.com", organizationName: "Acme", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == [
            "shared@example.com · Acme",
            "Shared@example.com · Sendbird",
        ])
        #expect(snapshots.map { $0.snapshot?.identity?.accountEmail } == [
            "shared@example.com",
            "Shared@example.com",
        ])
    }

    @Test
    func `appends account ordinal when shared emails also share an organization name`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird"),
                self.row(number: 4, email: "shared@example.com", organizationName: "Sendbird", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == [
            "shared@example.com · Sendbird · Account 4",
            "shared@example.com · Sendbird · Account 1",
        ])
        #expect(snapshots.map(\.id.opaqueID) == ["4", "1"])
        #expect(snapshots.map { $0.snapshot?.identity?.accountEmail } == [
            "shared@example.com",
            "shared@example.com",
        ])
        #expect(snapshots.map { $0.snapshot?.identity?.accountOrganization } == [nil, nil])
    }

    @Test
    func `appends account ordinal when same-mailbox emails differ only by case`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "Shared@example.com", organizationName: "Sendbird"),
                self.row(number: 4, email: "shared@example.com", organizationName: "Sendbird", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == [
            "shared@example.com · Sendbird · Account 4",
            "Shared@example.com · Sendbird · Account 1",
        ])
    }

    @Test
    func `prefers user alias over email and empty email ordinal`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird", alias: "Work"),
                self.row(number: 2, email: "shared@example.com", organizationName: "Acme"),
                self.row(number: 3, email: "", alias: "Empty slot")),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == ["Work", "shared@example.com · Acme", "Empty slot"])
        #expect(snapshots.map(\.id.opaqueID) == ["1", "2", "3"])
        #expect(snapshots.map { $0.snapshot?.identity?.accountOrganization } == [nil, nil, nil])
        #expect(snapshots.map { $0.snapshot?.identity?.accountEmail } == [
            "shared@example.com",
            "shared@example.com",
            nil,
        ])
    }

    @Test
    func `retained fingerprints skip email shaped aliases when the mailbox is empty`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "", alias: "owner@example.com", active: true)),
            now: self.now)
        let account = snapshots[0]
        #expect(account.displayLabel == "owner@example.com")
        #expect(account.accountEmail == nil)
        #expect(ClaudeSwapRetainedUsageStore.fingerprint(from: account) == nil)
        #expect(ClaudeSwapRetainedUsageStore.snapshotsForRetention(snapshots).isEmpty)
    }

    private func list(_ rows: ClaudeSwapAccountRow...) -> ClaudeSwapAccountList {
        ClaudeSwapAccountList(
            activeAccountNumber: rows.first { $0.isActive }?.number,
            accounts: rows)
    }

    private func row(
        number: Int,
        email: String,
        organizationName: String = "",
        alias: String? = nil,
        active: Bool = false) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: email,
            organizationName: organizationName,
            alias: alias,
            isActive: active,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: nil)
    }
}
