import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProviderChangelogLinkTests {
    @Test
    func `provider menu hides changelog action until enabled`() {
        let codexDescriptor = self.makeDescriptor(
            provider: .codex,
            suite: "ProviderChangelogLinkTests-codex-default")
        #expect(!self.actionTitles(from: codexDescriptor).contains("Changelog"))
    }

    private func makeDescriptor(
        provider: UsageProvider,
        suite: String,
        changelogLinksEnabled: Bool = false) -> MenuDescriptor
    {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        settings.statusChecksEnabled = false
        settings.providerChangelogLinksEnabled = changelogLinksEnabled

        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        return MenuDescriptor.build(
            provider: provider,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false,
            includeContextualActions: true)
    }

    private func actionTitles(from descriptor: MenuDescriptor) -> [String] {
        descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .action(title, _) = entry else { return nil }
                return title
            }
    }
}
