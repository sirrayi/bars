import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ProviderDetectionPolicyTests {
    @Test
    func `fresh install detects Codex and Claude Desktop without unconfigured Gemini`() {
        let enabled = ProviderDetectionPolicy.enabledProviders(signals: .init(
            codexCLIInstalled: true,
            claudeCLIInstalled: false,
            claudeDesktopInstalled: true))

        #expect(enabled == [.codex, .claude])
    }

    @Test
    func `Codex remains the fallback when no provider source is available`() {
        let enabled = ProviderDetectionPolicy.enabledProviders(signals: .init(
            codexCLIInstalled: false,
            claudeCLIInstalled: false,
            claudeDesktopInstalled: false))

        #expect(enabled == [.codex])
    }
}
