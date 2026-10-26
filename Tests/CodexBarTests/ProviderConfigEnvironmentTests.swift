import CodexBarCore
import Testing

struct ProviderConfigEnvironmentTests {
    @Test
    func `ignores legacy API key override for deepseek`() {
        let config = ProviderConfig(id: .deepseek, apiKey: "ds-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .deepseek,
            config: config)

        let key = DeepSeekSettingsReader.apiKeyEnvironmentKeys.first
        #expect(key != nil)
        guard let key else { return }

        #expect(env[key] == nil)
        #expect(ProviderTokenResolver.token(for: .deepseek, environment: env) == nil)
    }

    @Test
    func `projects the legacy DeepSeek Platform token and stable profile identifier`() {
        var config = ProviderConfig(
            id: .deepseek,
            apiKey: "legacy-api-key",
            cookieHeader: "browser-platform-token")
        config.deepseekProfileID = "/profiles/Profile 2"
        config.deepseekProfileScope = "account-id"
        let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .deepseek,
            config: config)

        #expect(env[DeepSeekSettingsReader.apiKeyEnvironmentKey] == nil)
        #expect(env[DeepSeekSettingsReader.platformTokenEnvironmentKey] == "browser-platform-token")
        #expect(env[DeepSeekSettingsReader.profileIDEnvironmentKey] == "chrome:Profile 2")
        #expect(env[DeepSeekSettingsReader.profileScopeEnvironmentKey] == "account-id")
    }

    @Test
    func `normalization preserves a legacy DeepSeek browser token and canonicalizes the profile path`() throws {
        var providerConfig = ProviderConfig(id: .deepseek, cookieHeader: "browser-platform-token")
        providerConfig.deepseekProfileID = "/profiles/Profile 2"
        providerConfig.deepseekProfileScope = " account-id "
        let config = CodexBarConfig(providers: [providerConfig]).normalized()
        let deepseek = try #require(config.providerConfig(for: .deepseek))

        #expect(deepseek.cookieHeader == "browser-platform-token")
        #expect(deepseek.deepseekProfileID == "chrome:Profile 2")
        #expect(deepseek.deepseekProfileScope == "account-id")
    }

    @Test
    func `deepseek config override leaves environment token alone`() {
        let config = ProviderConfig(id: .deepseek, apiKey: "config-token")
        let envKey = DeepSeekSettingsReader.apiKeyEnvironmentKeys[0]
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [envKey: "env-token"],
            provider: .deepseek,
            config: config)

        #expect(env[envKey] == "env-token")
        #expect(ProviderTokenResolver.token(for: .deepseek, environment: env) == "env-token")
    }
}
