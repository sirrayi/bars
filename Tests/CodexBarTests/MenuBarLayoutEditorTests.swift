import CodexBarCore
import CoreTransferable
import Foundation
import Observation
import Testing
import UniformTypeIdentifiers
@testable import CodexBar

struct MenuBarLayoutEditorTests {
    @Test
    func `saved history cost item uses the history window label`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let token = try JSONDecoder().decode(MenuBarLayoutToken.self, from: Data(#"{"cost30d":{}}"#.utf8))
            let metric = try JSONDecoder().decode(MenuBarConditionalMetric.self, from: Data(#""cost30d""#.utf8))
            #expect(token.editorLabel(provider: nil) == "Cost (History window)")
            #expect(token.editorAccessibilityLabel(provider: nil) == "Cost (History window)")
            #expect(metric.editorLabel(provider: nil) == "Cost (History window)")
        }
    }

    @Test
    func `time palette lists the compact run out token with a clear label`() {
        #expect(MenuBarLayoutPaletteTokens.time.contains(.runsOutCompact))
        #expect(MenuBarLayoutToken.runsOutCompact.editorLabel(provider: .claude) == "Runs out (compact)")
    }

    @Test
    func `cost window token is named after the history window`() {
        for provider in [nil, UsageProvider.claude] {
            #expect(MenuBarLayoutToken.costWindow.editorLabel(provider: provider) == "Cost (History window)")
            #expect(MenuBarLayoutToken.costWindow.editorAccessibilityLabel(provider: provider)
                == "Cost (History window)")
        }
        #expect(MenuBarLayoutToken.costToday.editorLabel(provider: nil) == "Cost today")
    }

    @Test
    func `cost window conditional metric is named after the history window`() {
        #expect(MenuBarConditionalMetric.costWindow.editorLabel(provider: nil) == "Cost (History window)")
        let conditional = MenuBarLayoutConditional(
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(
                    metric: .costWindow,
                    comparison: .greaterThanOrEqual,
                    threshold: 5))],
            thenToken: .costWindow,
            elseToken: .hidden)
        #expect(conditional.editorSummary(provider: nil)
            == "If Cost (History window) >= 5 USD then Cost (History window) else Hide")
    }

    @Test
    func `spend tokens are in the layout and conditional palettes`() {
        let spendUsage: [MenuBarLayoutToken] = [.percent(window: .spend), .pace(window: .spend)]
        let spendTime: [MenuBarLayoutToken] = [
            .windowResetCountdown(window: .spend), .windowResetAbsolute(window: .spend),
        ]
        let spendMoney: [MenuBarLayoutToken] = [.spendAmount, .spendBudget]
        #expect(spendUsage.allSatisfy(MenuBarLayoutPaletteTokens.usage(provider: .claude, snapshot: nil).contains))
        #expect(spendTime.allSatisfy(MenuBarLayoutPaletteTokens.time.contains))
        let branch = MenuBarLayoutPaletteTokens.conditionalBranch
        #expect((spendUsage + spendTime + spendMoney).allSatisfy(branch.contains))
    }

    @Test
    func `reset window choices are available in layout and conditional palettes`() {
        let choices: [MenuBarLayoutToken] = [
            .resetCountdown,
            .resetAbsolute,
            .windowResetCountdown(window: .session),
            .windowResetAbsolute(window: .session),
            .windowResetCountdown(window: .weekly),
            .windowResetAbsolute(window: .weekly),
        ]
        for token in choices {
            #expect(MenuBarLayoutPaletteTokens.time.contains(token))
            #expect(MenuBarLayoutPaletteTokens.conditionalBranch.contains(token))
        }
        for window in [PercentWindow.scopedWeekly, .automatic] {
            #expect(!MenuBarLayoutPaletteTokens.time.contains(.windowResetCountdown(window: window)))
            #expect(!MenuBarLayoutPaletteTokens.time.contains(.windowResetAbsolute(window: window)))
        }
    }

    @Test
    func `reset window labels distinguish countdown and absolute choices accessibly`() {
        for (window, title) in [(PercentWindow.session, L("Session")), (.weekly, L("Weekly"))] {
            let countdown = MenuBarLayoutToken.windowResetCountdown(window: window)
            let absolute = MenuBarLayoutToken.windowResetAbsolute(window: window)
            let countdownLabel = L("%@: %@", title, L("menu_bar_layout_token_resets_in"))
            let absoluteLabel = L("%@: %@", title, L("menu_bar_layout_token_reset_at"))

            #expect(countdown.editorLabel(provider: .claude) == countdownLabel)
            #expect(countdown.editorAccessibilityLabel(provider: .claude) == countdownLabel)
            #expect(countdown.editorSystemImage == "timer")
            #expect(absolute.editorLabel(provider: .claude) == absoluteLabel)
            #expect(absolute.editorAccessibilityLabel(provider: .claude) == absoluteLabel)
            #expect(absolute.editorSystemImage == "clock")
        }
        #expect(MenuBarLayoutToken.resetCountdown.editorLabel(provider: .claude)
            == L("menu_bar_layout_token_resets_in"))
        #expect(MenuBarLayoutToken.resetAbsolute.editorLabel(provider: .claude)
            == L("menu_bar_layout_token_reset_at"))
    }

    @Test
    func `palette tokens append and insert at a drop index`() {
        let initial = MenuBarLayout(lines: [[.icon, .resetCountdown]])

        let appended = MenuBarLayoutEditorMutations.append(.space, to: initial)
        #expect(appended.lines == [[.icon, .resetCountdown, .space]])

        let inserted = MenuBarLayoutEditorMutations.insert(
            .palette(.percent(window: .weekly)),
            at: MenuBarLayoutPosition(line: 0, index: 1),
            in: initial)
        #expect(inserted.lines == [[.icon, .percent(window: .weekly), .resetCountdown]])
    }

    @Test
    func `dragging within a line reorders without duplicating`() {
        let initial = MenuBarLayout(lines: [[.icon, .providerName, .resetCountdown]])
        let dragged = MenuBarLayoutDragItem.placed(
            .icon,
            at: MenuBarLayoutPosition(line: 0, index: 0),
            in: initial)

        let reordered = MenuBarLayoutEditorMutations.insert(
            dragged,
            at: MenuBarLayoutPosition(line: 0, index: 3),
            in: initial)

        #expect(reordered.lines == [[.providerName, .resetCountdown, .icon]])

        let unchanged = MenuBarLayoutEditorMutations.insert(
            .placed(.providerName, at: MenuBarLayoutPosition(line: 0, index: 1), in: initial),
            at: MenuBarLayoutPosition(line: 0, index: 1),
            in: initial)
        #expect(unchanged == initial)
    }

    @Test
    func `dragging between lines moves the token`() {
        let initial = MenuBarLayout(lines: [[.icon, .providerName], [.percent(window: .weekly)]])
        let dragged = MenuBarLayoutDragItem.placed(
            .providerName,
            at: MenuBarLayoutPosition(line: 0, index: 1),
            in: initial)

        let reordered = MenuBarLayoutEditorMutations.insert(
            dragged,
            at: MenuBarLayoutPosition(line: 1, index: 0),
            in: initial)

        #expect(reordered.lines == [[.icon], [.providerName, .percent(window: .weekly)]])
    }

    @Test
    func `stale drag source leaves the layout unchanged`() {
        let initial = MenuBarLayout(lines: [[.icon, .providerName]])
        let stale = MenuBarLayoutDragItem.placed(
            .icon,
            at: MenuBarLayoutPosition(line: 0, index: 1),
            in: initial)

        let result = MenuBarLayoutEditorMutations.insert(
            stale,
            at: MenuBarLayoutPosition(line: 0, index: 2),
            in: initial)

        #expect(result == initial)
    }

    @Test
    func `line break splits and rejoins the strip`() {
        let initial = MenuBarLayout(lines: [[.icon, .providerName, .percent(window: .automatic)]])

        let split = MenuBarLayoutEditorMutations.addLineBreak(to: initial, at: 2)
        #expect(split.lines == [[.icon, .providerName], [.percent(window: .automatic)]])
        #expect(MenuBarLayoutEditorMutations.removeLineBreak(from: split) == initial)
    }

    @Test
    func `line break preserves an empty second line until a token is dropped`() {
        let initial = MenuBarLayout(lines: [[.icon]])
        let split = MenuBarLayoutEditorMutations.addLineBreak(to: initial)
        #expect(split.lines == [[.icon], []])

        let inserted = MenuBarLayoutEditorMutations.insert(
            .palette(.percent(window: .session)),
            at: MenuBarLayoutPosition(line: 1, index: 0),
            in: split)
        #expect(inserted.lines == [[.icon], [.percent(window: .session)]])
    }

    @Test
    func `delete and drag out keep at least one token`() {
        let initial = MenuBarLayout(lines: [[.icon, .providerName]])
        let deleted = MenuBarLayoutEditorMutations.remove(
            at: MenuBarLayoutPosition(line: 0, index: 0),
            from: initial)
        #expect(deleted.lines == [[.providerName]])

        let lastToken = MenuBarLayoutDragItem.placed(
            .providerName,
            at: MenuBarLayoutPosition(line: 0, index: 0),
            in: deleted)
        #expect(MenuBarLayoutEditorMutations.remove(lastToken, from: deleted) == deleted)

        let staleToken = MenuBarLayoutDragItem.placed(
            .icon,
            at: MenuBarLayoutPosition(line: 0, index: 1),
            in: initial)
        #expect(MenuBarLayoutEditorMutations.remove(staleToken, from: initial) == initial)

        let changedDuringDrag = MenuBarLayout(lines: [[.icon, .resetCountdown]])
        let oldPayload = MenuBarLayoutDragItem.placed(
            .icon,
            at: MenuBarLayoutPosition(line: 0, index: 0),
            in: initial)
        #expect(MenuBarLayoutEditorMutations.remove(oldPayload, from: changedDuringDrag) == changedDuringDrag)

        let iconAndSpace = MenuBarLayout(lines: [[.icon, .space]])
        #expect(MenuBarLayoutEditorMutations.remove(
            at: MenuBarLayoutPosition(line: 0, index: 0),
            from: iconAndSpace) == iconAndSpace)
    }

    @Test
    func `drag payload codable round trips`() throws {
        let layout = MenuBarLayout(lines: [[.icon, .balance], [.providerName, .space, .percent(window: .automatic)]])
        let payload = MenuBarLayoutDragItem.placed(
            .percent(window: .automatic),
            at: MenuBarLayoutPosition(line: 1, index: 2),
            in: layout)

        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(MenuBarLayoutDragItem.self, from: data) == payload)
    }

    @Test
    @available(macOS 15.2, *)
    func `palette drag transfer representation round trips`() async throws {
        let payload = MenuBarLayoutDragItem.palette(.percent(window: .scopedWeekly))

        #expect(MenuBarLayoutDragItem.exportedContentTypes() == [.codexBarMenuLayoutItem])
        #expect(MenuBarLayoutDragItem.importedContentTypes() == [.codexBarMenuLayoutItem])

        let data = try await payload.exported(as: .codexBarMenuLayoutItem)
        let decoded = try await MenuBarLayoutDragItem(
            importing: data,
            contentType: .codexBarMenuLayoutItem)
        #expect(decoded == payload)
    }

    @Test
    func `conditional drag payload round trips`() throws {
        let payload = MenuBarLayoutDragItem.palette(.conditional(id: UUID()))

        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(MenuBarLayoutDragItem.self, from: data) == payload)
    }

    @Test
    func `conditional token appends like palette tokens`() {
        let initial = MenuBarLayout(lines: [[.icon, .resetCountdown]])
        let conditionalID = UUID()

        let appended = MenuBarLayoutEditorMutations.append(
            .conditional(id: conditionalID),
            to: initial)
        #expect(appended.lines == [[.icon, .resetCountdown, .conditional(id: conditionalID)]])
    }

    @Test
    func `conditional palette chips wrap instead of overflowing the pane`() {
        let spacing: CGFloat = 6

        // Two 100pt chips fit in 220pt (100 + 6 + 100); the third has to wrap.
        #expect(MenuBarLayoutChipFlowLayout.rows(
            widths: [100, 100, 100],
            maxWidth: 220,
            spacing: spacing) == [[0, 1], [2]])

        // Long localized names still get placed on their own row rather than dropped.
        #expect(MenuBarLayoutChipFlowLayout.rows(
            widths: [400],
            maxWidth: 220,
            spacing: spacing) == [[0]])
        #expect(MenuBarLayoutChipFlowLayout.rows(
            widths: [400, 120],
            maxWidth: 220,
            spacing: spacing) == [[0], [1]])

        // Chips that fit stay on one row, so a short library keeps hugging the leading edge.
        #expect(MenuBarLayoutChipFlowLayout.rows(
            widths: [80, 90],
            maxWidth: 220,
            spacing: spacing) == [[0, 1]])
    }
}
