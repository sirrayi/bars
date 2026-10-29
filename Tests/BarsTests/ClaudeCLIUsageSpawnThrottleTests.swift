import Foundation
import Testing
@testable import BarsCore

struct ClaudeCLIUsageSpawnThrottleTests {
    private actor AttemptRecorder {
        private var count = 0

        func record() -> Int {
            self.count += 1
            return self.count
        }

        func snapshot() -> Int {
            self.count
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            self.lock.withLock { self.value }
        }

        func advance(by interval: TimeInterval) {
            self.lock.withLock {
                self.value = self.value.addingTimeInterval(interval)
            }
        }
    }

    @Test
    func `background refresh reuses the cached CLI result within the spawn floor`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                let first = try await self.fetch(strategy, context: context, interaction: .background)
                let second = try await self.fetch(strategy, context: context, interaction: .background)

                #expect(await attempts.snapshot() == 1)
                #expect(second.usage.primary?.usedPercent == first.usage.primary?.usedPercent)
                #expect(second.usage.secondary?.usedPercent == first.usage.secondary?.usedPercent)
                #expect(second.usage.updatedAt == first.usage.updatedAt)
            }
        }
    }

    @Test
    func `Auto returns cached CLI usage after OAuth Keychain access is revoked`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment, sourceMode: .auto)
        let attempts = AttemptRecorder()
        let pipeline = ProviderFetchPipeline { _ in [RevokedOAuthStrategy(), strategy] }

        try await self.withGateStack {
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                    try await ClaudeStatusProbe.$fetchOverride.withValue(
                        self.successfulFetchOverride(attempts: attempts))
                    {
                        _ = try await self.fetch(strategy, context: context, interaction: .userInitiated)
                        let outcome = await ProviderInteractionContext.$current.withValue(.background) {
                            await pipeline.fetch(context: context, provider: .claude)
                        }

                        let result = try outcome.result.get()
                        #expect(result.strategyID == "claude.cli")
                        #expect(result.usage.primary?.usedPercent == 11)
                        #expect(await attempts.snapshot() == 1)
                        #expect(outcome.attempts.map(\.strategyID) == ["claude.oauth-revoked", "claude.cli"])
                    }
                }
            }
        }
    }

    @Test
    func `background refresh respawns the CLI after the spawn floor elapses`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))

        try await self.withGateStack {
            try await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                    let first = try await self.fetch(strategy, context: context, interaction: .background)
                    clock.advance(by: ClaudeCLIUsageSpawnThrottle.minimumBackgroundSpawnInterval + 1)
                    let second = try await self.fetch(strategy, context: context, interaction: .background)

                    #expect(await attempts.snapshot() == 2)
                    #expect(second.usage.primary?.usedPercent != first.usage.primary?.usedPercent)
                }
            }
        }
    }

    @Test
    func `a background probe cancelled mid-flight still leaves its result for reuse`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()
        let started = AsyncStream<Void>.makeStream()
        let slowProbe: ClaudeStatusProbe.FetchOverride = { _, _, _ in
            let attempt = await attempts.record()
            started.continuation.yield()
            // A cancelled probe would throw here, as the PTY capture does.
            try await Task.sleep(for: .milliseconds(200))
            return Self.makeStatusSnapshot(attempt: attempt)
        }

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(slowProbe) {
                // Closing the menu cancels the menu-open refresh after Claude has launched.
                let menuRefresh = Task { try await self.fetch(strategy, context: context, interaction: .background) }
                var probeStarts = started.stream.makeAsyncIterator()
                await probeStarts.next()
                menuRefresh.cancel()
                _ = try? await menuRefresh.value

                _ = try await self.fetch(strategy, context: context, interaction: .background)
                #expect(await attempts.snapshot() == 1)
            }
        }
    }

    @Test
    func `user initiated refresh always spawns the CLI`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                _ = try await self.fetch(strategy, context: context, interaction: .background)
                _ = try await self.fetch(strategy, context: context, interaction: .userInitiated)

                #expect(await attempts.snapshot() == 2)
            }
        }
    }

    @Test
    func `failed CLI fetches are not cached`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in
            let attempt = await attempts.record()
            if attempt == 1 {
                throw ExpectedFetchError.failed
            }
            return Self.makeStatusSnapshot(attempt: attempt)
        }

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                await #expect(throws: ExpectedFetchError.self) {
                    try await self.fetch(strategy, context: context, interaction: .userInitiated)
                }
                #expect(await attempts.snapshot() == 1)

                _ = try await self.fetch(strategy, context: context, interaction: .userInitiated)
                #expect(await attempts.snapshot() == 2)

                _ = try await self.fetch(strategy, context: context, interaction: .background)
                #expect(await attempts.snapshot() == 2)
            }
        }
    }

    @Test
    func `account profile change invalidates the cached CLI result`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                _ = try await self.fetch(strategy, context: context, interaction: .background)
                try Data(#"{"oauthAccount":{"accountUuid":"account-b"}}"#.utf8)
                    .write(to: profile.configURL, options: .atomic)
                _ = try await self.fetch(strategy, context: context, interaction: .background)

                #expect(await attempts.snapshot() == 2)
            }
        }
    }

    @Test
    func `owner CLI recovery pass bypasses the cached result`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let recoveryContext = self.makeContext(
            environment: profile.environment,
            claudeOwnerCLIRecoveryOnly: true)
        let attempts = AttemptRecorder()

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                _ = try await self.fetch(strategy, context: context, interaction: .background)
                _ = try await self.fetch(strategy, context: recoveryContext, interaction: .background)

                #expect(await attempts.snapshot() == 2)
            }
        }
    }

    @Test
    func `a session reset boundary invalidates the cached CLI result before the spawn floor elapses`() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start)
        // The cached session window resets halfway through the spawn floor.
        let floor = ClaudeCLIUsageSpawnThrottle.minimumBackgroundSpawnInterval
        let result = Self.makeFetchResult(sessionResetsAt: start.addingTimeInterval(floor / 2))
        let key = ClaudeCLIUsageSpawnThrottle.Key(
            binary: "/bin/echo",
            accountScope: "scope-a",
            useWebExtras: false,
            includePrepaidBalance: false)

        await ClaudeCLIUsageSpawnThrottle.withIsolatedStoreForTesting {
            await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                ClaudeCLIUsageSpawnThrottle.record(result, for: key)
                clock.advance(by: floor / 4)
                #expect(ClaudeCLIUsageSpawnThrottle.cachedResult(for: key) != nil)

                clock.advance(by: floor / 2)
                #expect(ClaudeCLIUsageSpawnThrottle.cachedResult(for: key) == nil)
            }
        }
    }

    @Test(arguments: [
        // A transcript write relative to the cached capture, and the resulting number of Claude launches.
        (nil as TimeInterval?, 1),
        (30, 2),
        (-60, 2),
        (-600, 1),
    ])
    func `periodic tick past the spawn floor relaunches only after local Claude activity`(
        transcriptOffset: TimeInterval?,
        expectedAttempts: Int) async throws
    {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        if let transcriptOffset {
            try Self.writeTranscript(
                in: profile.root,
                project: "-Users-example-project",
                modifiedAt: start.addingTimeInterval(transcriptOffset))
        }

        let attempts = try await self.fetchThenPeriodicTick(
            profile: profile,
            start: start,
            after: ClaudeCLIUsageSpawnThrottle.minimumBackgroundSpawnInterval + 1)

        #expect(attempts == expectedAttempts)
    }

    @Test
    func `periodic tick ignores transcripts from bars's own probe`() async throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        try Self.writeTranscript(
            in: profile.root,
            project: ClaudeProbeSessionArtifactCleaner.claudeProjectDirectoryName(
                for: ClaudeStatusProbe.dedicatedProbeWorkingDirectoryURL()),
            modifiedAt: start.addingTimeInterval(30))

        let attempts = try await self.fetchThenPeriodicTick(
            profile: profile,
            start: start,
            after: ClaudeCLIUsageSpawnThrottle.minimumBackgroundSpawnInterval + 1)

        #expect(attempts == 1)
    }

    @Test(arguments: [
        // Seconds since the last keyboard or pointer input when the tick runs, and the resulting launches.
        (10 as TimeInterval, 2),
        (ClaudeCLIUsageSpawnThrottle.minimumBackgroundSpawnInterval + 1, 1),
    ])
    func `periodic tick relaunches when the Mac was used since the capture`(
        secondsSinceUserInput: TimeInterval,
        expectedAttempts: Int) async throws
    {
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }

        let attempts = try await self.fetchThenPeriodicTick(
            profile: profile,
            start: Date(timeIntervalSince1970: 1_000_000),
            after: ClaudeCLIUsageSpawnThrottle.minimumBackgroundSpawnInterval + 1,
            secondsSinceUserInput: secondsSinceUserInput)

        #expect(attempts == expectedAttempts)
    }

    @Test
    func `periodic tick relaunches once the idle reuse bound elapses`() async throws {
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }

        let attempts = try await self.fetchThenPeriodicTick(
            profile: profile,
            start: Date(timeIntervalSince1970: 1_000_000),
            after: ClaudeCLIUsageSpawnThrottle.maximumIdlePeriodicReuse)

        #expect(attempts == 2)
    }

    @Test
    func `unidentified profiles are never cached`() async throws {
        let strategy = self.makeStrategy()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bars-claude-throttle-unidentified-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = self.makeContext(environment: ["CLAUDE_CONFIG_DIR": root.path])
        let attempts = AttemptRecorder()

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                _ = try await self.fetch(strategy, context: context, interaction: .background)
                _ = try await self.fetch(strategy, context: context, interaction: .background)

                #expect(await attempts.snapshot() == 2)
            }
        }
    }

    private enum ExpectedFetchError: Error {
        case failed
    }

    private struct RevokedOAuthStrategy: ProviderFetchStrategy {
        let id = "claude.oauth-revoked"
        let kind = ProviderFetchKind.oauth

        func isAvailable(_: ProviderFetchContext) async -> Bool {
            true
        }

        func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
            throw ClaudeOAuthCredentialsError.keychainAccessRevoked
        }

        func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
            context.sourceMode == .auto
        }
    }

    private func makeStrategy() -> ClaudeCLIFetchStrategy {
        ClaudeCLIFetchStrategy(
            useWebExtras: false,
            includePrepaidBalance: false,
            manualCookieHeader: nil,
            browserDetection: BrowserDetection(cacheTTL: 0),
            hasWebFallback: false)
    }

    private func makeContext(
        environment: [String: String],
        sourceMode: ProviderSourceMode = .cli,
        claudeOwnerCLIRecoveryOnly: Bool = false) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection, environment: environment),
            browserDetection: browserDetection,
            claudeOwnerCLIRecoveryOnly: claudeOwnerCLIRecoveryOnly)
    }

    private func makeProfile(accountID: String) throws -> (
        root: URL,
        configURL: URL,
        environment: [String: String])
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bars-claude-throttle-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent(".config.json")
        try Data(#"{"oauthAccount":{"accountUuid":"\#(accountID)"}}"#.utf8)
            .write(to: configURL, options: .atomic)
        return (
            root: root,
            configURL: configURL,
            environment: ["CLAUDE_CONFIG_DIR": root.path])
    }

    private func fetch(
        _ strategy: ClaudeCLIFetchStrategy,
        context: ProviderFetchContext,
        interaction: ProviderInteraction) async throws -> ProviderFetchResult
    {
        try await ProviderInteractionContext.$current.withValue(interaction) {
            try await strategy.fetch(context)
        }
    }

    /// One background fetch at `start`, then one periodic timer tick `interval` later; returns the launch count.
    /// Nobody has used the Mac for `secondsSinceUserInput` when the tick runs (a day unless stated).
    private func fetchThenPeriodicTick(
        profile: (root: URL, configURL: URL, environment: [String: String]),
        start: Date,
        after interval: TimeInterval,
        secondsSinceUserInput: TimeInterval = 24 * 60 * 60) async throws -> Int
    {
        let strategy = self.makeStrategy()
        var environment = profile.environment
        environment["HOME"] = profile.root.path
        let context = self.makeContext(environment: environment)
        let attempts = AttemptRecorder()
        let clock = TestClock(start)

        try await self.withGateStack {
            try await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                try await ClaudeCLIUsageSpawnThrottle.withSecondsSinceUserInputOverrideForTesting(
                    secondsSinceUserInput)
                {
                    try await ClaudeStatusProbe.$fetchOverride.withValue(
                        self.successfulFetchOverride(attempts: attempts))
                    {
                        _ = try await self.fetch(strategy, context: context, interaction: .background)
                        clock.advance(by: interval)
                        _ = try await ProviderRefreshTriggerContext.$current.withValue(.periodic) {
                            try await self.fetch(strategy, context: context, interaction: .background)
                        }
                    }
                }
            }
        }
        return await attempts.snapshot()
    }

    private static func writeTranscript(in configRoot: URL, project: String, modifiedAt: Date) throws {
        let directory = configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: transcript.path)
    }

    private func successfulFetchOverride(attempts: AttemptRecorder) -> ClaudeStatusProbe.FetchOverride {
        { _, _, _ in
            let attempt = await attempts.record()
            return Self.makeStatusSnapshot(attempt: attempt)
        }
    }

    private static func makeFetchResult(sessionResetsAt: Date?) -> ProviderFetchResult {
        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: 5 * 60,
                resetsAt: sessionResetsAt,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
        return ProviderFetchResult(
            usage: usage,
            credits: nil,
            sourceLabel: "claude",
            strategyID: "claude.cli",
            strategyKind: .cli)
    }

    private static func makeStatusSnapshot(attempt: Int) -> ClaudeStatusSnapshot {
        ClaudeStatusSnapshot(
            sessionPercentLeft: 90 - attempt,
            weeklyPercentLeft: 80 - attempt,
            opusPercentLeft: nil,
            accountEmail: "cli@example.com",
            accountOrganization: "CLI Org",
            loginMethod: "cli",
            primaryResetDescription: nil,
            secondaryResetDescription: nil,
            opusResetDescription: nil,
            rawText: "probe raw")
    }

    private func withGateStack<T>(
        operation: () async throws -> T) async rethrows -> T
    {
        try await ClaudeCLIUsageSpawnThrottle.withIsolatedStoreForTesting {
            try await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                    try await operation()
                }
            }
        }
    }
}
