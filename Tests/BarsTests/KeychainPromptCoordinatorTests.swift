import BarsCore
import Testing
@testable import Bars

struct KeychainPromptCoordinatorTests {
    @Test
    func `detects raw SwiftPM debug executable`() {
        #expect(KeychainPromptCoordinator.isUnbundledBarsExecutable(
            "/Users/me/bars/.build/arm64-apple-macosx/debug/bars"))
        #expect(KeychainPromptCoordinator.isUnbundledBarsExecutable(
            "/Users/me/bars/.build/debug/bars"))
    }

    @Test
    func `detects raw SwiftPM release executable`() {
        #expect(KeychainPromptCoordinator.isUnbundledBarsExecutable(
            "/Users/me/bars/.build/arm64-apple-macosx/release/bars"))
    }

    @Test
    func `detects custom SwiftPM scratch path`() {
        #expect(KeychainPromptCoordinator.isUnbundledBarsExecutable(
            "/tmp/bars-build/arm64-apple-macosx/debug/bars"))
    }

    @Test
    func `keeps packaged app keychain behavior`() {
        #expect(!KeychainPromptCoordinator.isUnbundledBarsExecutable(
            "/Applications/bars.app/Contents/MacOS/bars"))
        #expect(!KeychainPromptCoordinator.isUnbundledBarsExecutable(
            "/Users/me/bars/.build/package/bars.app/Contents/MacOS/bars"))
    }

    @Test
    func `ignores unrelated executable paths`() {
        #expect(!KeychainPromptCoordinator.isUnbundledBarsExecutable(
            "/Users/me/bars/.build/debug/BarsCLI"))
        #expect(!KeychainPromptCoordinator.isUnbundledBarsExecutable(""))
        #expect(!KeychainPromptCoordinator.isUnbundledBarsExecutable("bars"))
    }

    @Test
    func `browser cookie alert explains password handling and opt out`() {
        let model = KeychainPromptCoordinator.browserCookieAlertModel(label: "Chrome Safe Storage")

        #expect(model.title == "Keychain Access Required")
        #expect(model.message.contains("Chrome Safe Storage"))
        #expect(model.message.contains("macOS—not bars—handles any Mac login password entry"))
        #expect(model.message.contains("Settings → Advanced"))
        #expect(model.primaryButtonTitle == "OK")
        #expect(model.learnMoreButtonTitle == "Learn More…")
        #expect(model.documentationURL.hasSuffix("/docs/keychain-prompts.md"))
    }

    @Test
    func `provider alert preserves the requested keychain purpose`() {
        let context = KeychainPromptContext(
            kind: .claudeOAuth,
            service: "Claude Code-credentials",
            account: nil)

        let model = KeychainPromptCoordinator.alertModel(for: context)

        #expect(model.message.contains("Claude Code OAuth token"))
        #expect(model.message.contains("fetch your Claude usage"))
        #expect(model.learnMoreButtonTitle == "Learn More…")
    }

    @Test
    func `cookie explanations retain each provider and credential purpose`() {
        let providers: [(KeychainPromptContext.Kind, String)] = [
            (.opencodeCookie, "OpenCode"),
        ]
        for (kind, name) in providers {
            let model = KeychainPromptCoordinator.alertModel(for: .init(
                kind: kind, service: "fixture", account: nil))
            #expect(model.message.contains("your \(name) cookie header so it can fetch usage"))
        }
    }
}
