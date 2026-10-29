import Foundation
import Testing
@testable import Bars
@testable import BarsCore

@Suite(.serialized)
struct ClaudeCLITimeoutRetryTests {
    private actor AttemptRecorder {
        private var count = 0
        private var timeouts: [TimeInterval] = []

        func record(timeout: TimeInterval) -> Int {
            self.count += 1
            self.timeouts.append(timeout)
            return self.count
        }

        func snapshot() -> (count: Int, timeouts: [TimeInterval]) {
            (self.count, self.timeouts)
        }
    }

    private final class WebRequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ path: String) {
            self.lock.withLock {
                self.paths.append(path)
            }
        }

        func snapshot() -> [String] {
            self.lock.withLock {
                self.paths
            }
        }
    }

    @Test
    func `cli usage retries with longer timeout after transient probe failure`() async throws {
        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .cli)

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            let attempt = await attempts.record(timeout: timeout)
            if attempt == 1 {
                throw ClaudeStatusProbeError.timedOut
            }
            return ClaudeStatusSnapshot(
                sessionPercentLeft: 91,
                weeklyPercentLeft: 88,
                opusPercentLeft: nil,
                accountEmail: "cli@example.com",
                accountOrganization: "CLI Org",
                loginMethod: "cli",
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "probe raw")
        }

        let snapshot = try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
            try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                try await fetcher.loadLatestUsage(model: "sonnet")
            }
        }

        let recorded = await attempts.snapshot()
        #expect(recorded.count == 2)
        #expect(recorded.timeouts == [24, 60])
        #expect(snapshot.primary?.usedPercent == 9)
        #expect(snapshot.secondary?.usedPercent == 12)
        #expect(snapshot.accountEmail == "cli@example.com")
    }

    @Test
    func `auto cli usage does not retry unrecoverable parse failure`() async throws {
        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .auto,
            manualCookieHeader: "foo=bar")

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            _ = await attempts.record(timeout: timeout)
            throw ClaudeStatusProbeError.parseFailed("Missing Current session.")
        }

        await #expect(throws: ClaudeStatusProbeError.self) {
            try await self.withLoggedInCLIWithoutOAuth {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                    try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    }
                }
            }
        }

        let recorded = await attempts.snapshot()
        #expect(recorded.count == 1)
        #expect(recorded.timeouts == [12])
    }

    @Test
    func `auto cli usage retries loading panel before stale web fallback`() async throws {
        let attempts = AttemptRecorder()
        let webRequests = WebRequestRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .auto,
            manualCookieHeader: "sessionKey=sk-ant-session-token")

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            let attempt = await attempts.record(timeout: timeout)
            if attempt == 1 {
                throw ClaudeStatusProbeError.parseFailed("Claude CLI /usage is still loading usage data.")
            }
            return ClaudeStatusSnapshot(
                sessionPercentLeft: 95,
                weeklyPercentLeft: 93,
                opusPercentLeft: nil,
                accountEmail: "loading-cli@example.com",
                accountOrganization: "Loading CLI Org",
                loginMethod: "cli",
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "probe raw")
        }

        let snapshot = try await self.withLoggedInCLIWithoutOAuth {
            try await self.withClaudeWebStub(handler: { request in
                webRequests.record(request.url?.path ?? "<missing>")
                throw URLError(.userAuthenticationRequired)
            }, operation: {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                    try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    }
                }
            })
        }

        let recorded = await attempts.snapshot()
        #expect(recorded.count == 2)
        #expect(recorded.timeouts == [12, 60])
        #expect(webRequests.snapshot().isEmpty)
        #expect(snapshot.primary?.usedPercent == 5)
        #expect(snapshot.secondary?.usedPercent == 7)
        #expect(snapshot.accountEmail == "loading-cli@example.com")
    }

    @Test
    func `auto cli usage retries timeout when cli is final source`() async throws {
        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .auto,
            manualCookieHeader: "foo=bar")

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            let attempt = await attempts.record(timeout: timeout)
            if attempt == 1 {
                throw ClaudeStatusProbeError.timedOut
            }
            return ClaudeStatusSnapshot(
                sessionPercentLeft: 72,
                weeklyPercentLeft: 64,
                opusPercentLeft: nil,
                accountEmail: "auto-cli@example.com",
                accountOrganization: "Auto CLI Org",
                loginMethod: "cli",
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "probe raw")
        }

        let snapshot = try await self.withLoggedInCLIWithoutOAuth {
            try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                    try await fetcher.loadLatestUsage(model: "sonnet")
                }
            }
        }

        let recorded = await attempts.snapshot()
        #expect(recorded.count == 2)
        #expect(recorded.timeouts == [12, 60])
        #expect(snapshot.primary?.usedPercent == 28)
        #expect(snapshot.secondary?.usedPercent == 36)
        #expect(snapshot.accountEmail == "auto-cli@example.com")
    }

    @Test
    func `cli usage does not retry cancelled probe`() async throws {
        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .cli)

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            _ = await attempts.record(timeout: timeout)
            throw CancellationError()
        }

        await #expect(throws: CancellationError.self) {
            try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                    try await fetcher.loadLatestUsage(model: "sonnet")
                }
            }
        }

        let recorded = await attempts.snapshot()
        #expect(recorded.count == 1)
        #expect(recorded.timeouts == [24])
    }

    @Test
    func `cli usage records background cooldown after rate limit`() async {
        ClaudeCLIRateLimitGate.resetForTesting()
        defer { ClaudeCLIRateLimitGate.resetForTesting() }

        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .cli)

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            _ = await attempts.record(timeout: timeout)
            throw ClaudeStatusProbeError.parseFailed(ClaudeCLIRateLimitGate.message)
        }

        await ProviderInteractionContext.$current.withValue(.background) {
            await #expect(throws: ClaudeStatusProbeError.self) {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                    try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    }
                }
            }
        }

        let recordedAfterRateLimit = await attempts.snapshot()
        #expect(recordedAfterRateLimit.count == 1)
        #expect(recordedAfterRateLimit.timeouts == [24])
        #expect(ClaudeCLIRateLimitGate.currentBlockedUntil() != nil)

        await ProviderInteractionContext.$current.withValue(.background) {
            await #expect(throws: ClaudeUsageError.self) {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                    try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    }
                }
            }
        }

        let recordedAfterBlockedRetry = await attempts.snapshot()
        #expect(recordedAfterBlockedRetry.count == 1)
        #expect(recordedAfterBlockedRetry.timeouts == [24])
    }

    @Test(arguments: [false, true])
    func `cli usage records background cooldown when neither usage answer loads`(ptyTimedOut: Bool) async throws {
        // The fake `claude` answers the direct `/usage` fallback. It prints nothing after the PTY reported the load
        // failure itself, and Claude's "Failed to load usage data" after a PTY that only timed out.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-no-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claude = directory.appendingPathComponent("claude")
        let directOutput = ptyTimedOut ? "printf '%s\\n' 'Failed to load usage data'" : "exit 0"
        try "#!/bin/sh\n\(directOutput)\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: claude.path)
        // Claude answers an endpoint failure with only "Failed to load usage data" once it has no saved rows.
        let ptyFailure: ClaudeStatusProbeError = ptyTimedOut
            ? .timedOut
            : .parseFailed("Claude CLI could not load usage data. Open the CLI and retry `/usage`.")

        await ClaudeCLIRateLimitGate.withIsolatedCooldownForTesting {
            await self.expectCooldownWhenNeitherUsageAnswerLoads(ptyFailure: ptyFailure, directBinary: claude.path)
        }
    }

    private func expectCooldownWhenNeitherUsageAnswerLoads(
        ptyFailure: ClaudeStatusProbeError,
        directBinary: String) async
    {
        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .cli)
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            _ = await attempts.record(timeout: timeout)
            throw ptyFailure
        }

        let error = await ProviderInteractionContext.$current.withValue(.background) {
            await #expect(throws: ClaudeStatusProbeError.self) {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(directBinary) {
                    try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    }
                }
            }
        }

        guard case let .parseFailed(message) = error else {
            Issue.record("Expected a parse failure, got \(String(describing: error))")
            return
        }
        #expect(message == ClaudeCLIRateLimitGate.loadFailedMessage)
        #expect(error.map { ClaudeUsageFetcher.isCLIRateLimitError($0) } == true)
        #expect(await (attempts.snapshot()).count == 1)
        #expect(ClaudeCLIRateLimitGate.currentBlockedUntil() != nil)
    }

    @Test
    func `background cooldown lets the next scheduled probe run when it ends within a minute`() async {
        await ClaudeCLIRateLimitGate.withIsolatedCooldownForTesting {
            let trippedAt = Date()
            ClaudeCLIRateLimitGate.recordRateLimit(now: trippedAt)
            // A tick on a five-minute beat can fire seconds before the cooldown its predecessor started ends.
            let nextTick = trippedAt.addingTimeInterval(300 - 5)

            #expect(ClaudeCLIRateLimitGate.blockedUntil(interaction: .background, now: nextTick) == nil)
            #expect(ClaudeCLIRateLimitGate.currentBlockedUntil(now: nextTick) != nil)
            #expect(ClaudeCLIRateLimitGate.blockedUntil(
                interaction: .background,
                now: trippedAt.addingTimeInterval(60)) != nil)
        }
    }

    @Test
    func `user initiated cli usage bypasses rate limit cooldown`() async throws {
        ClaudeCLIRateLimitGate.resetForTesting()
        defer { ClaudeCLIRateLimitGate.resetForTesting() }
        ClaudeCLIRateLimitGate.recordRateLimit()

        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .cli)

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            _ = await attempts.record(timeout: timeout)
            return ClaudeStatusSnapshot(
                sessionPercentLeft: 89,
                weeklyPercentLeft: 83,
                opusPercentLeft: nil,
                accountEmail: "manual-cli@example.com",
                accountOrganization: "Manual CLI Org",
                loginMethod: "cli",
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "probe raw")
        }

        await ProviderInteractionContext.$current.withValue(.background) {
            await #expect(throws: ClaudeUsageError.self) {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                    try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    }
                }
            }
        }

        #expect(await (attempts.snapshot()).timeouts.isEmpty)

        let snapshot = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
            try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                    try await fetcher.loadLatestUsage(model: "sonnet")
                }
            }
        }

        let recorded = await attempts.snapshot()
        #expect(recorded.count == 1)
        #expect(recorded.timeouts == [24])
        #expect(snapshot.primary?.usedPercent == 11)
        #expect(snapshot.secondary?.usedPercent == 17)
        #expect(snapshot.accountEmail == "manual-cli@example.com")
        #expect(ClaudeCLIRateLimitGate.currentBlockedUntil() == nil)
    }

    private func withLoggedInCLIWithoutOAuth<T>(operation: () async throws -> T) async rethrows -> T {
        let missingCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-claude-creds-\(UUID().uuidString).json")
        return try await KeychainCacheStore.withServiceOverrideForTesting("rat-107-\(UUID().uuidString)") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            return try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                        try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            try await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: nil,
                                fingerprint: nil)
                            {
                                try await ClaudeCLIAuthStatusProbe.withResultOverrideForTesting(true) {
                                    try await operation()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func withClaudeWebStub<T>(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
        operation: () async throws -> T) async rethrows -> T
    {
        let registered = URLProtocol.registerClass(ClaudeAutoFetcherStubURLProtocol.self)
        ClaudeAutoFetcherStubURLProtocol.handler = handler
        defer {
            if registered {
                URLProtocol.unregisterClass(ClaudeAutoFetcherStubURLProtocol.self)
            }
            ClaudeAutoFetcherStubURLProtocol.handler = nil
        }
        return try await operation()
    }
}
