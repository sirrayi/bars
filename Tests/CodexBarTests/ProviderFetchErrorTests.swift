import Foundation
import Testing
@testable import CodexBarCore

enum ProviderFetchErrorTests {
    private static func context() -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}

private enum TerminalFixtureFailure: LocalizedError {
    case first, terminal, resolved

    var errorDescription: String? {
        "HTTP \(self) failure: sensitive-payload"
    }
}

private struct TerminalFixtureStrategy: ProviderFetchStrategy {
    let id: String
    let error: TerminalFixtureFailure?
    var allowsFallback = false
    var cancelTask = false
    var throwCancellation = false
    var routed: LockIsolated<[TerminalFixtureFailure]>?
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool { true }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        if self.cancelTask { withUnsafeCurrentTask { $0?.cancel() } }
        if self.throwCancellation { throw CancellationError() }
        if let error { throw error }
        return self.makeResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            sourceLabel: self.id)
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        if let routed, let failure = error as? TerminalFixtureFailure {
            routed.setValue(routed.value + [failure])
        }
        return self.allowsFallback
    }
}

private actor DelayedRetryStrategyState {
    private(set) var fetchCount = 0

    func nextFetchShouldFail() -> Bool {
        self.fetchCount += 1
        return self.fetchCount == 1
    }
}

private struct DelayedRetryStrategy: ProviderFetchStrategy {
    let state: DelayedRetryStrategyState
    let id = "delayed-retry-test"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        if await self.state.nextFetchShouldFail() {
            throw ProviderFetchClassifiedError(
                kind: .rateLimited,
                message: "retry fixture",
                retryAfterSeconds: 3)
        }
        return self.makeResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            sourceLabel: "test")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private actor RetryDelayRecorder {
    private(set) var values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        self.values.append(value)
    }
}
