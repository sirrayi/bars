import Foundation
import Testing
@testable import BarsCore

struct ClaudeCLIBackgroundAvailabilityTests {
    @Test(arguments: [
        (false, ClaudeStatusProbeError.timedOut, false),
        (true, ClaudeStatusProbeError.timedOut, true),
        (true, ClaudeStatusProbeError.parseFailed("Claude CLI /usage is still loading usage data."), true),
        (true, ClaudeStatusProbeError.authenticationFailed("Synthetic authentication timeout"), false),
    ])
    func `transient failures preserve only established background CLI availability`(
        established: Bool, failure: ClaudeStatusProbeError, remainsAvailable: Bool) async throws
    {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "timeout-account")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        await self.withBackgroundGates(
            keychainDisabled: !established,
            promptMode: .always,
            establishedBinary: established ? "/bin/echo" : nil,
            establishedEnvironment: context.env,
            oauthCredentialsMissing: true)
        {
            #expect(await strategy.isAvailable(context))
            let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in throw failure }
            let error = await #expect(throws: ClaudeStatusProbeError.self) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                    try await strategy.fetch(context)
                }
            }
            #expect(error?.localizedDescription == failure.localizedDescription)
            #expect(await strategy.isAvailable(context) == remainsAvailable)
        }
    }

    @Test(arguments: [
        (ClaudeStatusProbeError.parseFailed(ClaudeCLIRateLimitGate.message), false, true),
        (ClaudeStatusProbeError.parseFailed(ClaudeCLIRateLimitGate.lastKnownUsageMessage), false, true),
        (ClaudeStatusProbeError.parseFailed(ClaudeCLIRateLimitGate.loadFailedMessage), false, true),
        // The cooldown's own answer while it holds background probes back.
        (ClaudeUsageError.parseFailed(ClaudeCLIRateLimitGate.message), false, true),
        (ClaudeStatusProbeError.parseFailed("Claude CLI /usage is still loading usage data."), true, true),
        (ClaudeStatusProbeError.parseFailed("Claude CLI /usage is still loading usage data."), false, false),
        (ClaudeStatusProbeError.parseFailed("missing session data"), true, false),
    ] as [(any Error & Sendable, Bool, Bool)])
    func `an endpoint refusal keeps background CLI availability even before a first success`(
        failure: any Error & Sendable,
        established: Bool,
        preserves: Bool)
    {
        #expect(
            ClaudeCLIFetchStrategy.preservesBackgroundAvailability(after: failure, established: established)
                == preserves)
    }

    @Test
    func `successful background Auto usage keeps availability through a later transient failure`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "background-success-account")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let success: ClaudeStatusProbe.FetchOverride = { _, _, _ in
            ClaudeStatusSnapshot(
                sessionPercentLeft: 88,
                weeklyPercentLeft: 60,
                opusPercentLeft: nil,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: nil,
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "stub")
        }
        let timeout: ClaudeStatusProbe.FetchOverride = { _, _, _ in throw ClaudeStatusProbeError.timedOut }

        try await self.withBackgroundGates(keychainDisabled: false, promptMode: .onlyOnUserAction) {
            // Separate spawn-throttle stores keep the cached success from short-circuiting the failing fetch.
            _ = try await ClaudeCLIUsageSpawnThrottle.withIsolatedStoreForTesting {
                try await ClaudeStatusProbe.$fetchOverride.withValue(success) {
                    try await strategy.fetch(context)
                }
            }
            await ClaudeCLIUsageSpawnThrottle.withIsolatedStoreForTesting {
                await #expect(throws: ClaudeStatusProbeError.self) {
                    try await ClaudeStatusProbe.$fetchOverride.withValue(timeout) {
                        try await strategy.fetch(context)
                    }
                }
                #expect(await strategy.isAvailable(context))
            }
        }
    }

    @Test
    func `disabled Keychain allows cold background Auto usage without an established marker`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        await self.withBackgroundGates(keychainDisabled: true, promptMode: .never) {
            #expect(await strategy.isAvailable(context))
        }
    }

    @Test(arguments: ClaudeOAuthKeychainPromptMode.allCases, [true, false])
    func `enabled Keychain allows cold background Auto usage on an identified profile`(
        promptMode: ClaudeOAuthKeychainPromptMode,
        oauthCredentialsMissing: Bool) async throws
    {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        // No foreground fetch has established a marker. Neither the prompt policy nor whether OAuth credentials
        // are absent or merely unreadable decides it: the identified profile is enough.
        await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: promptMode,
            oauthCredentialsMissing: oauthCredentialsMissing)
        {
            #expect(await strategy.isAvailable(context))
        }
    }

    @Test
    func `disabled Keychain allows background Auto after foreground availability is established`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        await self.withBackgroundGates(
            keychainDisabled: true,
            promptMode: .never,
            establishedBinary: "/bin/echo",
            establishedEnvironment: context.env)
        {
            #expect(await strategy.isAvailable(context))
        }
    }

    @Test(arguments: ClaudeOAuthKeychainPromptMode.allCases)
    func `background explicit OAuth never reaches interactive CLI`(promptMode: ClaudeOAuthKeychainPromptMode) async {
        let strategy = self.makeStrategy()
        let context = self.makeContext(sourceMode: .oauth)

        await self.withBackgroundGates(keychainDisabled: true, promptMode: promptMode) {
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `failed disabled Keychain exception revokes later background Auto usage`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
            -> ClaudeStatusSnapshot = { _, _, _ in
                throw ExpectedFetchError.failed
            }

        // Present-but-denied throughout: a revoked marker after a failed fetch is not the same as a
        // durable OAuth absence, so the deadlock-breaker must not fire.
        await self.withBackgroundGates(keychainDisabled: true, promptMode: .never, oauthCredentialsMissing: false) {
            #expect(await strategy.isAvailable(context))
            await #expect(throws: ExpectedFetchError.self) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                    try await strategy.fetch(context)
                }
            }
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `failed background Auto usage stays revoked when OAuth credentials are absent`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
            -> ClaudeStatusSnapshot = { _, _, _ in
                throw ExpectedFetchError.failed
            }

        // A revoked marker is a deliberate "not available right now" outcome from a failed fetch. Confirmed
        // OAuth absence does not reopen it; only the next foreground success does.
        await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: .always,
            establishedBinary: "/bin/echo",
            establishedEnvironment: context.env,
            oauthCredentialsMissing: true)
        {
            #expect(await strategy.isAvailable(context))
            await #expect(throws: ExpectedFetchError.self) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                    try await strategy.fetch(context)
                }
            }
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `background Auto usage stays blocked for an unidentified profile`()
        async throws
    {
        let strategy = self.makeStrategy()
        // No profile is created here: the config file is verifiably absent, so
        // `ClaudeAccountProfile.identifiedSessionScope` returns nil and `captureMarker` can never produce a
        // marker for this environment — there is nothing to establish, revoke, or bind a background attempt to.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bars-claude-unidentified-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = self.makeContext(environment: ["CLAUDE_CONFIG_DIR": root.path])

        // Even with `.always` and confirmed OAuth absence, a profile with no identity stays blocked: a failed
        // attempt here could never be recorded as a revocation, so nothing would bound repeated launches.
        await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: .always,
            oauthCredentialsMissing: true)
        {
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `cancelled disabled Keychain exception keeps later background Auto usage available`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
            -> ClaudeStatusSnapshot = { _, _, _ in
                throw CancellationError()
            }

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            await KeychainAccessGate.withTaskOverrideForTesting(true) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                        await ProviderInteractionContext.$current.withValue(.background) {
                            #expect(await strategy.isAvailable(context))
                            await #expect(throws: CancellationError.self) {
                                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                                    try await strategy.fetch(context)
                                }
                            }
                            #expect(await strategy.isAvailable(context))
                        }
                    }
                }
            }
        }
    }

    @Test
    func `user initiated explicit OAuth retains interactive CLI recovery`() async {
        let strategy = self.makeStrategy()
        let context = self.makeContext(sourceMode: .oauth)

        await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                #expect(await strategy.isAvailable(context))
            }
        }
    }

    @Test
    func `background Auto revocation does not cross config profiles`() async throws {
        let strategy = self.makeStrategy()
        let profileA = try self.makeProfile(accountID: "account-a")
        let profileB = try self.makeProfile(accountID: "account-b")
        defer {
            try? FileManager.default.removeItem(at: profileA.root)
            try? FileManager.default.removeItem(at: profileB.root)
        }
        let contextA = self.makeContext(environment: profileA.environment)
        let contextB = self.makeContext(environment: profileB.environment)
        let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
            -> ClaudeStatusSnapshot = { _, _, _ in
                throw ExpectedFetchError.failed
            }

        await self.withBackgroundGates(keychainDisabled: false, promptMode: .onlyOnUserAction) {
            await #expect(throws: ExpectedFetchError.self) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                    try await strategy.fetch(contextA)
                }
            }
            #expect(await !strategy.isAvailable(contextA))
            #expect(await strategy.isAvailable(contextB))
        }
    }

    @Test
    func `background Auto revocation does not cross active account changes`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
            -> ClaudeStatusSnapshot = { _, _, _ in
                throw ExpectedFetchError.failed
            }

        try await self.withBackgroundGates(keychainDisabled: false, promptMode: .onlyOnUserAction) {
            await #expect(throws: ExpectedFetchError.self) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                    try await strategy.fetch(context)
                }
            }
            #expect(await !strategy.isAvailable(context))
            // A different active account is a different marker, so account A's failure does not block it.
            try Data(#"{"oauthAccount":{"accountUuid":"account-b"}}"#.utf8)
                .write(to: profile.configURL, options: .atomic)
            #expect(await strategy.isAvailable(context))
            // Without an identity there is nothing to revoke against, so the profile stays blocked.
            try FileManager.default.removeItem(at: profile.configURL)
            #expect(await !strategy.isAvailable(context))
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

    private enum ExpectedFetchError: Error {
        case failed
    }

    private func makeContext(
        sourceMode: ProviderSourceMode = .auto,
        environment: [String: String] = [:]) -> ProviderFetchContext
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
            browserDetection: browserDetection)
    }

    private func makeProfile(accountID: String) throws -> (
        root: URL,
        configURL: URL,
        environment: [String: String])
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bars-claude-background-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent(".config.json")
        try Data(#"{"oauthAccount":{"accountUuid":"\#(accountID)"}}"#.utf8)
            .write(to: configURL, options: .atomic)
        return (
            root: root,
            configURL: configURL,
            environment: ["CLAUDE_CONFIG_DIR": root.path])
    }

    /// Assembles the gate stack every test in this file needs: an isolated background-availability
    /// store, the Keychain-disable/prompt-policy pair under test, the resolved CLI binary, a background
    /// interaction context, and (optionally) a pre-established marker or a pinned
    /// `directCredentialIsMissing` answer.
    /// - Parameter oauthCredentialsMissing: `nil` (the default) leaves `directCredentialIsMissingOverride`
    ///   unset, matching production when no test needs to pin that specific signal.
    private func withBackgroundGates<T>(
        keychainDisabled: Bool,
        promptMode: ClaudeOAuthKeychainPromptMode,
        binary: String = "/bin/echo",
        establishedBinary: String? = nil,
        establishedEnvironment: [String: String]? = nil,
        oauthCredentialsMissing: Bool? = nil,
        operation: () async throws -> T) async rethrows -> T
    {
        try await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            if let establishedBinary {
                ClaudeCLIBackgroundAvailability.establish(
                    binary: establishedBinary,
                    environment: establishedEnvironment ?? [:])
            }
            return try await KeychainAccessGate.withTaskOverrideForTesting(keychainDisabled) {
                try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(promptMode) {
                    try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(binary) {
                        try await ProviderInteractionContext.$current.withValue(.background) {
                            try await ClaudeOAuthFetchStrategy.$directCredentialIsMissingOverride
                                .withValue(oauthCredentialsMissing) {
                                    try await operation()
                                }
                        }
                    }
                }
            }
        }
    }
}
