import Testing
@testable import BarsCLI
@testable import BarsCore

struct CLIWebFallbackTests {
    private func makeContext(
        runtime: ProviderRuntime = .cli,
        sourceMode: ProviderSourceMode = .auto,
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: true,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private func makeClaudeSettingsSnapshot(cookieHeader: String?) -> ProviderSettingsSnapshot {
        ProviderSettingsSnapshot.make(
            claude: .init(
                usageDataSource: .auto,
                webExtrasEnabled: false,
                cookieSource: .manual,
                manualCookieHeader: cookieHeader))
    }

    @Test
    func `claude falls back when no session key`() {
        let context = self.makeContext()
        let strategy = ClaudeWebFetchStrategy(browserDetection: BrowserDetection(cacheTTL: 0))
        #expect(strategy.shouldFallback(on: ClaudeWebAPIFetcher.FetchError.noSessionKeyFound, context: context))
        #expect(strategy.shouldFallback(on: ClaudeWebAPIFetcher.FetchError.unauthorized, context: context))
    }

    @Test
    func `claude CLI fallback is enabled only for app auto`() {
        let webAvailableStrategy = ClaudeCLIFetchStrategy(
            useWebExtras: false,
            includePrepaidBalance: false,
            manualCookieHeader: nil,
            browserDetection: BrowserDetection(cacheTTL: 0),
            hasWebFallback: true)
        let webUnavailableStrategy = ClaudeCLIFetchStrategy(
            useWebExtras: false,
            includePrepaidBalance: false,
            manualCookieHeader: nil,
            browserDetection: BrowserDetection(cacheTTL: 0),
            hasWebFallback: false)
        let error = ClaudeUsageError.parseFailed("cli failed")
        let webAvailableSettings = self.makeClaudeSettingsSnapshot(cookieHeader: "sessionKey=sk-ant-test")
        let webUnavailableSettings = self.makeClaudeSettingsSnapshot(cookieHeader: "foo=bar")

        #expect(webAvailableStrategy.shouldFallback(
            on: error,
            context: self.makeContext(runtime: .app, sourceMode: .auto, settings: webAvailableSettings)))
        #expect(!webUnavailableStrategy.shouldFallback(
            on: error,
            context: self.makeContext(runtime: .app, sourceMode: .auto, settings: webUnavailableSettings)))
        #expect(!webAvailableStrategy.shouldFallback(
            on: error,
            context: self.makeContext(runtime: .app, sourceMode: .cli)))
        #expect(!webAvailableStrategy.shouldFallback(
            on: error,
            context: self.makeContext(runtime: .app, sourceMode: .web)))
        #expect(!webAvailableStrategy.shouldFallback(
            on: error,
            context: self.makeContext(runtime: .app, sourceMode: .oauth)))
        #expect(!webAvailableStrategy.shouldFallback(
            on: error,
            context: self.makeContext(runtime: .cli, sourceMode: .auto)))
    }

    @Test
    func `claude web fallback is disabled for app auto`() {
        let strategy = ClaudeWebFetchStrategy(browserDetection: BrowserDetection(cacheTTL: 0))
        let error = ClaudeWebAPIFetcher.FetchError.unauthorized
        #expect(strategy.shouldFallback(on: error, context: self.makeContext(runtime: .cli, sourceMode: .auto)))
        #expect(!strategy.shouldFallback(on: error, context: self.makeContext(runtime: .app, sourceMode: .auto)))
    }
}
