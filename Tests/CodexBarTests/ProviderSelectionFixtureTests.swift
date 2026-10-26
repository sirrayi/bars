import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProviderSelectionFixtureTests {
    @Test
    func `arranging unchanged unselected providers does not repeat config work`() {
        let settings = testSettingsStore(suiteName: "provider-fixture-work", userDefaults: InMemoryUserDefaults())
        settings.selectedMenuProvider = nil
        enableTestProviders([.codex], settings: settings)
        let revision = settings.configRevision

        enableTestProviders([.codex], settings: settings)

        #expect(settings.configRevision == revision)
    }
}
