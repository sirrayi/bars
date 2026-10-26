import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLISnapshotTests {
    @Test
    func `renders text snapshot for codex`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "pro")
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: "today at 3:00 PM"),
            secondary: .init(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: "Fri at 9:00 AM"),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: CreditsSnapshot(remaining: 42, events: [], updatedAt: Date()),
            context: RenderContext(
                header: "Codex 1.2.3 (codex-cli)",
                status: ProviderStatusPayload(
                    indicator: .minor,
                    description: "Degraded performance",
                    updatedAt: Date(timeIntervalSince1970: 0),
                    url: "https://status.example.com"),
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Codex 1.2.3 (codex-cli)"))
        #expect(output.contains("Status: Partial outage – Degraded performance"))
        #expect(output.contains("Codex"))
        #expect(output.contains("Session: 88% left"))
        #expect(output.contains("Weekly: 75% left"))
        #expect(output.contains("Credits: 42"))
        #expect(output.contains("Account: user@example.com"))
        #expect(output.contains("Plan: Pro 20x"))
    }

    @Test
    func `renders Codex limit reset credits`() {
        let now = Date()
        let expiresAt = now.addingTimeInterval(7200)
        let resetCredits = CodexRateLimitResetCreditsSnapshot(
            credits: [
                CodexRateLimitResetCredit(
                    id: "credit-1",
                    resetType: "codex_rate_limits",
                    status: .available,
                    grantedAt: Date(timeIntervalSince1970: 0),
                    expiresAt: expiresAt,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: nil,
                    description: nil),
                CodexRateLimitResetCredit(
                    id: "expired-credit",
                    resetType: "codex_rate_limits",
                    status: .available,
                    grantedAt: Date(timeIntervalSince1970: 0),
                    expiresAt: now,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: nil,
                    description: nil),
            ],
            availableCount: 99,
            updatedAt: Date(timeIntervalSince1970: 0))
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            codexResetCredits: resetCredits,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Codex (oauth)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(output.contains("Limit Reset Credits: 1 available"))
        #expect(output.contains("Next reset credit expires"))
    }

    @Test
    func `renders Codex prolite plan with multiplier display name`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "prolite")
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: "today at 3:00 PM"),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 1.2.3 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Plan: Pro 5x"))
        #expect(!output.contains("Plan: Pro Lite"))
        #expect(!output.contains("Plan: Prolite"))
    }

    @Test
    func `renders Codex plan only limits as unavailable`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "pro")
        let snap = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 1.2.3 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Limits: not available"))
        #expect(output.contains("Account: user@example.com"))
        #expect(output.contains("Plan: Pro 20x"))
        #expect(!output.contains("Session:"))
        #expect(!output.contains("Weekly:"))
    }

    @Test
    func `renders text snapshot for claude without weekly`() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 2, windowMinutes: nil, resetsAt: nil, resetDescription: "3pm (Europe/Vienna)"),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Claude Code 2.0.69 (claude)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Session: 98% left"))
        #expect(!output.contains("Weekly:"))
    }

    @Test
    func `renders Claude Max multiplier without uppercasing x`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Claude Max 5x")
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 2, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Claude (oauth)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Plan: Claude Max 5x"))
        #expect(!output.contains("Plan: Claude Max 5X"))
    }

    @Test
    func `renders pace line when weekly has reset`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: nil,
            secondary: .init(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(output.contains("Pace:"))
    }

    @Test
    func `configured work days affect weekly text and JSON pace`() throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let resetsAt = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 14)))
        let now = resetsAt.addingTimeInterval(-72 * 60 * 60)
        let snap = UsageSnapshot(
            primary: nil,
            secondary: .init(
                usedPercent: 60,
                windowMinutes: 10080,
                resetsAt: resetsAt,
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown,
                weeklyWorkDays: 5),
            now: now)
        #expect(output.contains("Pace: On pace | Expected 60% used | Lasts until reset"))

        let pace = try #require(CLIRenderer.providerPacePayload(
            provider: .codex,
            snapshot: snap,
            weeklyWorkDays: 5,
            now: now)?.secondary)
        #expect(pace.expectedUsedPercent == 60)
        #expect(pace.summary == "On pace | Expected 60% used | Lasts until reset")
    }

    @Test
    func `renders session pace line when session window has reset`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        #expect(output.contains("Session: 80% left"))
        // 2h remaining of a 5h window => 3h elapsed => 60% expected; even rate easily lasts to reset.
        #expect(output.contains("Pace: 40% in reserve | Expected 60% used | Lasts until reset | 1.5× headroom"))
    }

    @Test
    func `renders Claude session pace using five hour default window`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Claude Code 2.0.69 (claude)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        // windowMinutes is nil, so the 5-hour (300 minute) session default must drive the pace.
        #expect(output.contains("Pace: 40% in reserve | Expected 60% used | Lasts until reset"))
        #expect(!output.contains("1.5× headroom"))
    }

    @Test
    func `renders session pace deficit with run out estimate`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        // 1h elapsed of a 5h window => 20% expected vs 50% used => burning ahead of pace.
        // Session mirrors the GUI's "Projected empty" wording (weekly uses "Runs out").
        #expect(output.contains("Pace: 30% in deficit | Expected 20% used | Projected empty in"))
        #expect(!output.contains("Runs out"))
    }

    @Test
    func `renders session pace on track and lasts until reset`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Exactly halfway through a 5h window with 50% used => On pace (delta 0); the even rate
        // means the quota lasts precisely to the reset.
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2.5 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        #expect(output.contains("Pace: On pace | Expected 50% used | Lasts until reset"))
    }

    @Test
    func `hides session pace for unsupported provider`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .deepseek,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "DeepSeek 0.0.0 (deepseek)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(!output.contains("Pace:"))
    }

    @Test
    func `hides session pace for non-session primary window`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Claude with no 5-hour data falls a 7-day window back into `primary`; it must not be
        // paced as a "Session" (that would print "Projected empty …" over a weekly window).
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Claude Code 2.0.69 (claude)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        #expect(!output.contains("Pace:"))
        #expect(CLIRenderer.providerPacePayload(provider: .claude, snapshot: snap, now: now) == nil)
    }

    @Test
    func `encodes JSON with secondary null when missing`() throws {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snap)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode JSON payload")
            return
        }

        #expect(json.contains("\"secondary\":null"))
    }

    @Test
    func `parses output format`() {
        #expect(OutputFormat(argument: "json") == .json)
        #expect(OutputFormat(argument: "TEXT") == .text)
        #expect(OutputFormat(argument: "invalid") == nil)
    }

    @Test
    func `defaults to usage when no command provided`() {
        #expect(CodexBarCLI.effectiveArgv([]) == ["usage"])
        #expect(CodexBarCLI.effectiveArgv(["--format", "json"]).first == "usage")
        #expect(CodexBarCLI.effectiveArgv(["usage", "--format", "json"]).first == "usage")
    }

    @Test
    func `status line is last and colored when TTY`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "pro")
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Claude Code 2.0.58 (claude)",
                status: ProviderStatusPayload(
                    indicator: .critical,
                    description: "Major outage",
                    updatedAt: nil,
                    url: "https://status.claude.com"),
                useColor: true,
                resetStyle: .absolute))

        let lines = output.split(separator: "\n")
        #expect(lines.last?.contains("Status: Critical issue – Major outage") == true)
        #expect(output.contains("\u{001B}[31mStatus")) // red for critical
    }

    @Test
    func `output has ansi when TTY even without status`() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 1, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: true,
                resetStyle: .absolute))

        #expect(output.contains("\u{001B}["))
    }

    @Test
    func `tty output colors header and usage`() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 95, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 80, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: true,
                resetStyle: .absolute))

        #expect(output.contains("\u{001B}[1;95m== Codex 0.0.0 (codex-cli) ==\u{001B}[0m"))
        #expect(output.contains("Session: \u{001B}[31m5% left\u{001B}[0m")) // red <10% left
        #expect(output.contains("Weekly: \u{001B}[33m20% left\u{001B}[0m")) // yellow <25% left
    }

    @Test
    func `devin overage balance without primary window omits generic cost line`() {
        let snap = UsageSnapshot(
            primary: nil,
            secondary: .init(usedPercent: 42, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 48.0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: Date(timeIntervalSince1970: 0)),
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CLIRenderer.renderText(
            provider: .devin,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Devin (devin)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))
        #expect(output.contains("Extra usage: $48.00"))
        #expect(!output.contains("Cost:"))
        #expect(!output.contains(" / 0.0"))
    }

    @Test
    func `renders opencode go session and weekly pace lines`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: .init(
                usedPercent: 23,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(5 * 24 * 3600),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .opencodego,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "OpenCode Go (web)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        #expect(output.contains("5-hour: 80% left"))
        // 2h remaining of a 5h window => 3h elapsed => 60% expected; opencode go is not codex so no headroom suffix.
        #expect(output.contains("Pace: 40% in reserve | Expected 60% used | Lasts until reset"))
        #expect(output.contains("Weekly: 77% left"))
        // 5d remaining of a 7d window => 2d elapsed => 28.57% expected (29% displayed), delta -5.57 => -6 displayed.
        #expect(output.contains("Pace: 6% in reserve | Expected 29% used | Lasts until reset"))
        #expect(!output.contains("1.5× headroom"))
    }

    @Test
    func `returns opencode go pace payload for primary and secondary`() throws {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: .init(
                usedPercent: 23,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(5 * 24 * 3600),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let pace = try #require(CLIRenderer.providerPacePayload(provider: .opencodego, snapshot: snap, now: now))
        #expect(pace.primary != nil)
        #expect(pace.primary?.stage == "farBehind")
        #expect(pace.primary?.deltaPercent == -40)
        #expect(pace.primary?.expectedUsedPercent == 60)
        #expect(pace.primary?.summary == "40% in reserve | Expected 60% used | Lasts until reset")
        #expect(pace.secondary != nil)
        #expect(pace.secondary?.stage == "slightlyBehind")
        #expect(pace.secondary?.deltaPercent == -6)
        #expect(pace.secondary?.expectedUsedPercent == 29)
        #expect(pace.secondary?.summary == "6% in reserve | Expected 29% used | Lasts until reset")
    }

    @Test
    func `returns opencode go primary-only pace when weekly usage is missing`() throws {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let pace = try #require(CLIRenderer.providerPacePayload(provider: .opencodego, snapshot: snap, now: now))
        #expect(pace.primary != nil)
        #expect(pace.secondary == nil)
    }

    @Test
    func `hides opencode go primary pace when window exceeds five hours`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: 400,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        #expect(CLIRenderer.providerPacePayload(provider: .opencodego, snapshot: snap, now: now) == nil)
    }
}
