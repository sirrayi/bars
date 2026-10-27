import BarsCore
import Foundation
import Testing
@testable import Bars

@MainActor
struct ProviderSettingsIntegrationTests {
    @Test
    func `reordering visible providers preserves saved configuration for unknown providers`() throws {
        let absent = try #require(ProviderInstanceID(rawValue: "absent-fixture-provider"))
        let settings = testSettingsStore(
            suiteName: #function,
            userDefaults: InMemoryUserDefaults())
        // Model a provider entry that is no longer shipped but is already present in the loaded config.
        settings.updateConfig(reason: "test", affectsBackgroundWork: false) { config in
            var entry = ProviderConfig(id: absent, enabled: false)
            entry.apiKey = "synthetic-plugin-key"
            config.setProviderConfig(entry)
        }
        #expect(settings.configSnapshot.providerConfig(for: absent)?.apiKey == "synthetic-plugin-key")
        let before = settings.orderedProviders()
        #expect(!before.contains(absent))
        settings.moveProvider(fromOffsets: IndexSet(integer: 0), toOffset: before.count)

        #expect(settings.orderedProviders().last == before.first)
        #expect(settings.configSnapshot.providerConfig(for: absent)?.apiKey == "synthetic-plugin-key")
        #expect(settings.configSnapshot.providerConfig(for: absent)?.enabled == false)
        #expect(settings.configSnapshot.providers.count(where: { $0.id == absent }) == 1)
    }

    @Test
    func `settings links resolve their destination only when clicked`() async {
        var resolutions = 0
        let destination: () -> URL? = {
            resolutions += 1
            return nil
        }
        let action = ProviderSettingsActionDescriptor.openURL(id: "fixture", title: "Fixture", url: destination())
        #expect(resolutions == 0)
        await action.perform()
        #expect(resolutions == 1)
    }
}
