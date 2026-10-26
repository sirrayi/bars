import CodexBarCore
import Testing
@testable import CodexBar

struct MenuOpenRefreshPlanTests {
    @Test
    func `refresh all skips token cost refresh when no providers are enabled`() {
        let plan = MenuOpenRefreshPlan.resolve(.init(
            refreshAllOnOpen: true,
            enabledProviders: [],
            visibleProviders: [],
            refreshingProviders: [],
            staleProviders: [],
            missingProviders: []))

        #expect(plan.providers.isEmpty)
        #expect(!plan.refreshTokenCost)
    }

    @Test
    func `ordinary refresh skips fresh providers`() {
        let plan = MenuOpenRefreshPlan.resolve(.init(
            refreshAllOnOpen: false,
            enabledProviders: [.codex],
            visibleProviders: [.codex],
            refreshingProviders: [],
            staleProviders: [],
            missingProviders: []))

        #expect(plan.providers.isEmpty)
    }
}
