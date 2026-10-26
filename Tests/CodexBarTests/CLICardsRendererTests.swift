import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLICardsRendererTests {
    @Test
    func `computes column count from terminal width`() {
        #expect(CLICardsRenderer.columnCount(terminalWidth: 80) == 2)
        #expect(CLICardsRenderer.columnCount(terminalWidth: 120) == 3)
        #expect(CLICardsRenderer.columnCount(terminalWidth: 160) == 4)
        #expect(CLICardsRenderer.columnCount(terminalWidth: 30) == 1)
    }

    @Test
    func `renders single codex card without color`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "pro")
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: "today at 3:00 PM"),
            secondary: .init(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: "Fri at 9:00 AM"),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .codex,
            snapshot: snapshot,
            credits: CreditsSnapshot(remaining: 42, events: [], updatedAt: Date()),
            source: "oauth",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .absolute,
            weeklyWorkDays: nil,
            now: Date()))

        let output = CLICardsRenderer.render(cards: [card], failures: [], terminalWidth: 80, useColor: false)

        #expect(output.contains("Codex"))
        #expect(output.contains("[oauth]"))
        #expect(output.contains("PLAN Pro 20x"))
        #expect(output.contains("Session"))
        #expect(output.contains("88% left"))
        #expect(output.contains("[ "))
        #expect(output.contains("━"))
        #expect(output.contains("Credits:"))
        #expect(output.contains("42 left"))
        #expect(output.contains("@ user@example.com"))
        #expect(output.contains("╰"))
    }

    @Test
    func `card includes account line`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "pro")
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .codex,
            snapshot: snapshot,
            credits: nil,
            source: "cli",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .absolute,
            weeklyWorkDays: nil,
            now: Date()))

        let lines = CLICardsRenderer.renderCard(card, width: 48, useColor: false)
        let joined = lines.joined(separator: "\n")

        #expect(joined.contains("@ user@example.com"))
        #expect(joined.contains("Session"))
        #expect(!joined.contains("Plan: Pro 20x"))
    }

    @Test
    func `renders two card grid at fixed width`() {
        let codex = CLICardModel(
            provider: .codex,
            title: "Codex",
            sourceLabel: "oauth",
            planBadge: "Pro",
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 88, resetText: nil)],
            extraLines: [],
            statusLine: nil)
        let claude = CLICardModel(
            provider: .claude,
            title: "Claude",
            sourceLabel: "web",
            planBadge: "Max",
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 50, resetText: nil)],
            extraLines: [],
            statusLine: nil)

        let output = CLICardsRenderer.render(cards: [codex, claude], failures: [], terminalWidth: 120, useColor: false)

        #expect(output.contains("Codex"))
        #expect(output.contains("Claude"))
        #expect(output.contains("88% left"))
        #expect(output.contains("50% left"))
        #expect(output.components(separatedBy: "╰").count >= 3)
    }

    @Test
    func `brief mode renders usage table`() {
        let card = CLICardModel(
            provider: .claude,
            title: "Claude",
            sourceLabel: "web",
            planBadge: "Max",
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 2, resetText: "⏳ Resets in 1h 49m")],
            extraLines: [],
            statusLine: nil)
        let rows = CLICardsBriefRenderer.makeRows(cards: [card])
        let output = CLICardsBriefRenderer.render(
            rows: rows,
            failures: [],
            terminalWidth: 80,
            useColor: false,
            now: Date(timeIntervalSince1970: 0))

        #expect(output.contains("codexbar • AI Usage & Limits"))
        #expect(output.contains("Provider"))
        #expect(output.contains("Claude"))
        #expect(output.contains("web"))
        #expect(output.contains("Max"))
        #expect(output.contains("98%"))
        #expect(output.contains("█"))
        #expect(output.contains("1h 49m"))
        #expect(output.contains("⚠ Warnings:"))
        let tableLine = output.split(separator: "\n").first { $0.hasPrefix("┌") } ?? ""
        #expect(tableLine.count >= 50)
        #expect(tableLine.count <= 72)
    }

    @Test
    func `synthetic quota lanes do not replace real brief usage`() {
        let snapshot = UsageSnapshot(
            primary: .init(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: .init(
                usedPercent: 20,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .claude,
            snapshot: snapshot,
            credits: nil,
            source: "oauth",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Date(timeIntervalSince1970: 0)))
        let rows = CLICardsBriefRenderer.makeRows(cards: [card])

        #expect(card.metrics.map(\.label) == ["Weekly"])
        #expect(rows.first?.usedPercent == 20)
    }

    @Test
    func `card metrics honor reset display style`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = UsageSnapshot(
            primary: .init(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)
        let countdown = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .codex,
            snapshot: snapshot,
            credits: nil,
            source: "oauth",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: now))
        let absolute = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .codex,
            snapshot: snapshot,
            credits: nil,
            source: "oauth",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .absolute,
            weeklyWorkDays: nil,
            now: now))

        #expect(countdown.metrics.first?.resetText != absolute.metrics.first?.resetText)
        #expect(countdown.metrics.first?.resetText?.contains("in 1h") == true)
        #expect(absolute.metrics.first?.resetAt == now.addingTimeInterval(3600))
    }

    @Test
    func `brief rows preserve account identity`() {
        let cards = [
            CLICardModel(
                provider: .codex,
                title: "Codex",
                sourceLabel: "oauth",
                planBadge: "Pro",
                accountLine: "one@x.dev",
                infoLines: [],
                metrics: [CLICardMetric(label: "Session", remainingPercent: 80, resetText: nil)],
                extraLines: [],
                statusLine: nil),
            CLICardModel(
                provider: .codex,
                title: "Codex",
                sourceLabel: "oauth",
                planBadge: "Pro",
                accountLine: "two@x.dev",
                infoLines: [],
                metrics: [CLICardMetric(label: "Session", remainingPercent: 60, resetText: nil)],
                extraLines: [],
                statusLine: nil),
        ]

        let output = CLICardsBriefRenderer.render(
            rows: CLICardsBriefRenderer.makeRows(cards: cards),
            failures: [],
            terminalWidth: 80,
            useColor: false,
            now: Date(timeIntervalSince1970: 0))

        #expect(output.contains("one@x.dev"))
        #expect(output.contains("two@x.dev"))
    }

    @Test
    func `enhanced mode uses truecolor gradient bars`() {
        let card = CLICardModel(
            provider: .codex,
            title: "Codex",
            sourceLabel: "oauth",
            planBadge: "Pro",
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 50, resetText: nil)],
            extraLines: [],
            statusLine: nil)
        let output = CLICardsRenderer.render(
            cards: [card],
            failures: [],
            terminalWidth: 80,
            useColor: true,
            enhanced: true)
        #expect(output.contains("38;2;"))
        #expect(output.contains("48;2;"))
        #expect(output.contains("[ "))
    }

    @Test
    func `claude swap active account renders without inferred plan`() {
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "active@example.com",
                accountOrganization: nil,
                loginMethod: "claude-swap"))
        let account = ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: "2"),
            provider: .claude,
            displayLabel: "active@example.com",
            isActive: true,
            snapshot: snapshot,
            error: nil,
            sourceLabel: "claude-swap")
        let card = CLICardsRenderer.makeClaudeSwapCard(
            account: account,
            renderOptions: CLIClaudeSwapCardsRenderOptions(
                status: nil,
                useColor: false,
                resetStyle: .countdown,
                weeklyWorkDays: nil,
                now: Date(timeIntervalSince1970: 0)))
        let full = CLICardsRenderer.renderCard(card, width: 38, useColor: false).joined(separator: "\n")
        let brief = CLICardsBriefRenderer.render(
            rows: CLICardsBriefRenderer.makeRows(cards: [card]),
            failures: [],
            terminalWidth: 40,
            useColor: false,
            now: Date(timeIntervalSince1970: 0))

        #expect(card.planBadge == nil)
        #expect(full.contains("@ active@example.com [active]"))
        #expect(!full.contains("PLAN Claude-Swap"))
        #expect(brief.contains("[active]"))
        #expect(!brief.contains("Claude-Swap"))
        #expect(full.split(separator: "\n").allSatisfy { $0.count == 38 })
        #expect(brief.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy { $0.count <= 40 })
    }

    @Test
    func `claude swap sentinel text survives full and brief projections`() {
        let account = ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: "7"),
            provider: .claude,
            displayLabel: "bad\u{1B}[31m\r\n" + String(repeating: "x", count: 300),
            isActive: true,
            snapshot: nil,
            error: "API-key account; subscription usage is unavailable.",
            sourceLabel: "claude-swap")
        let card = CLICardsRenderer.makeClaudeSwapCard(
            account: account,
            renderOptions: CLIClaudeSwapCardsRenderOptions(
                status: nil,
                useColor: false,
                resetStyle: .countdown,
                weeklyWorkDays: nil,
                now: Date(timeIntervalSince1970: 0)))
        let full = CLICardsRenderer.renderCard(card, width: 42, useColor: false).joined(separator: "\n")
        let brief = CLICardsBriefRenderer.render(
            rows: CLICardsBriefRenderer.makeRows(cards: [card]),
            failures: [],
            terminalWidth: 80,
            useColor: false,
            now: Date(timeIntervalSince1970: 0))
        let briefRow = brief.split(separator: "\n").first { $0.contains("API-key") } ?? ""

        #expect(card.accountLine?.unicodeScalars.count == CLIClaudeSwapText.labelScalarLimit)
        #expect(card.accountLine?.contains("\u{1B}") == false)
        #expect(card.accountLine?.contains("\n") == false)
        #expect(card.isActive)
        #expect(full.contains("[active]"))
        #expect(full.contains("API-key account;"))
        #expect(full.contains("subscription usage"))
        #expect(full.contains("unavailable."))
        #expect(brief.contains("Claude [active]"))
        #expect(brief.contains("API-key account"))
        #expect(briefRow.hasSuffix(" — │"))
        #expect(card.metrics.isEmpty)
    }
}
