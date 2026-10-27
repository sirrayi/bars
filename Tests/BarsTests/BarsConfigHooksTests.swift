import BarsCore
import Foundation
import Testing

struct BarsConfigHooksTests {
    @Test
    func `hooks survive config round trip`() throws {
        let hooks = HooksConfig(
            enabled: true,
            events: [
                HookRule(
                    id: "quota-low",
                    event: .quotaLow,
                    provider: "opencode",
                    threshold: 0.9,
                    executable: "/usr/bin/true",
                    timeoutSeconds: 30),
            ])
        let config = BarsConfig(
            providers: [ProviderConfig(id: .claude, enabled: true)],
            hooks: hooks)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BarsConfig.self, from: data)

        #expect(decoded.hooks == hooks)
    }
}

struct BarsConfigShareUsageTests {
    private static let legacyJSON = Data(#"{"version":1,"providers":[{"id":"opencode","enabled":true}]}"#.utf8)

    @Test
    func `sharing is opt in and legacy configs omit the flag on round trip`() throws {
        var config = try BarsConfig.decode(from: Self.legacyJSON)
        #expect(!config.shareUsageWithCLI)
        #expect(config.providers.first?.enabled == true)
        for enabled in [false, true, false] {
            config.shareUsageWithCLI = enabled
            let data = try config.encodedData()
            #expect(try #require(String(data: data, encoding: .utf8)).contains("shareUsageWithCLI") == enabled)
            #expect(try BarsConfig.decode(from: data).shareUsageWithCLI == enabled)
        }
    }
}
