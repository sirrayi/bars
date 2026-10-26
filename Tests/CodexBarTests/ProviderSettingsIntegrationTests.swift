import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProviderSettingsIntegrationTests {
    @Test
    func `reordering visible providers preserves saved configuration for absent plugins`() throws {
        let absent = try #require(ProviderInstanceID(rawValue: "absent-fixture-plugin"))
        let settings = testSettingsStore(
            suiteName: #function,
            userDefaults: InMemoryUserDefaults())
        // Model a plugin becoming unavailable after its configuration is already loaded.
        settings.updatePluginConfig(instanceID: absent) {
            $0.enabled = false
            $0.apiKey = "synthetic-plugin-key"
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
