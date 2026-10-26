import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct MergedIconPresentationTests {
    @Test
    func `first line conditional retains hidden branches and predicate dependencies`() {
        let conditional = MenuBarLayoutConditional(
            clauses: [.init(
                combinator: nil,
                predicate: .init(metric: .weeklyResetsIn, comparison: .lessThan, threshold: 1))],
            thenToken: .resetCountdown,
            elseToken: .hidden)
        let original = MenuBarLayoutResolution.stored(MenuBarLayout(lines: [
            [.conditional(id: conditional.id)], [.costToday],
        ]))
        let projected = Self.presentation().renderedResolution(original, for: .claude)
        let tokens = projected.layout.flattenedTokens(conditionals: [conditional])
        #expect(tokens.contains(.resetCountdown))
        #expect(projected.layout.lines == [[.conditional(id: conditional.id)]])
        #expect(!tokens.contains(.costToday))
        #expect(projected.layout.referencedConditionalPredicates(conditionals: [conditional])
            .map(\.metric) == [.weeklyResetsIn])
    }

    private static func presentation(
        providers: [UsageProvider] = [.codex, .claude],
        top: UsageProvider? = nil,
        bottom: UsageProvider? = nil,
        mergeIcons: Bool = true,
        iconStyle: MenuBarIconStyle = .iconAndPercent,
        style: MergedIconDisplayStyle = .stacked) -> MergedIconPresentation
    {
        MergedIconPresentation(
            mergeIcons: mergeIcons,
            iconStyle: iconStyle,
            requestedStyle: style,
            eligibleProviders: providers,
            preferredTop: top,
            preferredBottom: bottom)
    }
}
