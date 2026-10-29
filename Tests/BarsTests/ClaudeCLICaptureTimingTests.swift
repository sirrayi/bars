import Foundation
import Testing
@testable import BarsCore

struct ClaudeCLICaptureTimingTests {
    @Test(arguments: [
        // Claude Code 2.1 idle box: placeholder prompt between two rules, no footer.
        (#"────❯try"howdoiloganerror?"────"#, true),
        ("────❯────?forshortcuts", true),
        ("welcometoclaude", false),
        // A dialog selection list is not the input box.
        ("doyouwanttocontinue?❯1.yes2.no", false),
    ])
    func `idle input box moves the first command ahead of the startup delay`(screen: String, isReady: Bool) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let startupBound = now.addingTimeInterval(1.5)
        let expected = isReady ? now : startupBound

        #expect(ClaudeCLISession.commandReadyAt(startupBound, normalizedScreen: screen, now: now) == expected)
        // An already-earlier bound, such as a reused session, is never pushed later.
        let earlier = now.addingTimeInterval(-1)
        #expect(ClaudeCLISession.commandReadyAt(earlier, normalizedScreen: screen, now: now) == earlier)
    }

    @Test
    func `capture after the idle input box returns the panel`() async throws {
        let fixture = try self.makeFakeClaude(panel: #"printf 'Current session\r\n9%% used\r\nDONE\r\n'"#)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = ClaudeCLISession(workingDirectory: fixture.directory)

        let output = try await session.capture(
            subcommand: "/usage",
            binary: fixture.binary.path,
            accountScope: "synthetic-account",
            timeout: 5,
            environment: fixture.environment,
            idleTimeout: nil,
            stopOnSubstrings: ["DONE"],
            settleAfterStop: 0)
        await session.reset()

        #expect(output.contains("9% used"))
    }

    @Test(arguments: [
        ("currentsession40%usedresetsat5pmrefreshing\u{2026}esctocancel", false),
        ("currentsession40%usedrefreshing...esctocancel", false),
        ("currentsession13%usedcurrentweek(allmodels)2%usedesctocancel", true),
        ("loadingusagedata\u{2026}esctocancel", false),
        ("youarecurrentlyusingyoursubscriptiontopoweryourclaudecodeusage", true),
        ("youarecurrentlyusingyoursubscriptiontopoweryourclaudecodeusagerefreshing\u{2026}", false),
    ])
    func `usage capture is final once live values replace the refreshing footer`(screen: String, expected: Bool) {
        #expect(ClaudeStatusProbe.usageCaptureIsFinal(screen) == expected)
    }

    @Test
    func `usage reports the live values that replace the last known rows`() async throws {
        // Claude 2.1 opens on its last-known rows above a "Refreshing…" footer, then redraws the live response.
        let fixture = try self.makeFakeClaude(panel: #"""
        printf 'Current session\r\n40%% used\r\nRefreshing\xe2\x80\xa6\r\n'
        /bin/sleep 0.6
        printf '\033[2J\033[HCurrent session\r\n13%% used\r\nCurrent week (all models)\r\n2%% used\r\n'
        """#)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = ClaudeStatusProbe(claudeBinary: fixture.binary.path, timeout: 8, environment: fixture.environment)

        let snapshot = try await ClaudeStatusProbe.$statusIdentityStoreOverrideForTesting.withValue(
            ClaudeStatusProbe.StatusIdentityStore())
        {
            try await ClaudeCLISession.withIsolatedSessionForTesting { try await probe.fetch() }
        }

        #expect(snapshot.sessionPercentLeft == 87)
        #expect(snapshot.weeklyPercentLeft == 98)
    }

    @Test
    func `usage still refreshing at the deadline fails instead of reporting last known values`() async throws {
        let fixture = try self.makeFakeClaude(
            panel: #"printf 'Current session\r\n40%% used\r\nRefreshing\xe2\x80\xa6\r\n'"#)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = ClaudeStatusProbe(claudeBinary: fixture.binary.path, timeout: 1, environment: fixture.environment)

        await #expect(throws: ClaudeStatusProbeError.self) {
            try await ClaudeStatusProbe.$statusIdentityStoreOverrideForTesting.withValue(
                ClaudeStatusProbe.StatusIdentityStore())
            {
                try await ClaudeCLISession.withIsolatedSessionForTesting { try await probe.fetch() }
            }
        }
    }

    @Test(arguments: [
        ("could not refresh", ClaudeCLIRateLimitGate.lastKnownUsageMessage),
        ("rate limited until 3:33am", ClaudeCLIRateLimitGate.message),
    ])
    func `last known rows that Claude could not refresh are never reported as current`(
        reason: String,
        expectedMessage: String) async throws
    {
        // Claude 2.1 redraws the rows saved at its last successful fetch under this notice when the endpoint refuses.
        let fixture = try self.makeFakeClaude(panel: """
        printf 'Current session\\r\\n66%% used\\r\\nShowing last-known usage as of 3:03am (\(reason))\\r\\n'
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = ClaudeStatusProbe(claudeBinary: fixture.binary.path, timeout: 8, environment: fixture.environment)

        let error = await #expect(throws: ClaudeStatusProbeError.self) {
            try await ClaudeStatusProbe.$statusIdentityStoreOverrideForTesting.withValue(
                ClaudeStatusProbe.StatusIdentityStore())
            {
                try await ClaudeCLISession.withIsolatedSessionForTesting { try await probe.fetch() }
            }
        }

        guard case let .parseFailed(message) = error else {
            Issue.record("Expected a parse failure, got \(String(describing: error))")
            return
        }
        #expect(message == expectedMessage)
        // Both answers hold background probes off the endpoint for the rate-limit cooldown.
        #expect(error.map { ClaudeUsageFetcher.isCLIRateLimitError($0) } == true)
    }

    @Test(arguments: [
        "Usage endpoint is rate limited until 4:24am.",
        "Usage endpoint is rate limited. Please try again in a moment.",
    ])
    func `a rate limited endpoint with no saved rows ends the capture at once`(notice: String) async throws {
        // With nothing saved to show, Claude 2.1 replaces the panel with this notice and draws no usage rows.
        let fixture = try self.makeFakeClaude(panel: "printf '\(notice)\\r\\n'")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = ClaudeStatusProbe(claudeBinary: fixture.binary.path, timeout: 8, environment: fixture.environment)
        let started = ContinuousClock.now

        let error = await #expect(throws: ClaudeStatusProbeError.self) {
            try await ClaudeStatusProbe.$statusIdentityStoreOverrideForTesting.withValue(
                ClaudeStatusProbe.StatusIdentityStore())
            {
                try await ClaudeCLISession.withIsolatedSessionForTesting { try await probe.fetch() }
            }
        }

        guard case let .parseFailed(message) = error else {
            Issue.record("Expected a parse failure, got \(String(describing: error))")
            return
        }
        #expect(message == ClaudeCLIRateLimitGate.message)
        // Waiting for usage rows that never come would run until the 8-second capture deadline.
        #expect(ContinuousClock.now - started < .seconds(4))
    }

    @Test(arguments: [
        ClaudeCLIRateLimitGate.message,
        ClaudeCLIRateLimitGate.lastKnownUsageMessage,
        ClaudeCLIRateLimitGate.loadFailedMessage,
    ])
    func `endpoint refusals read as they are rather than as parse failures`(message: String) {
        #expect(ClaudeStatusProbeError.parseFailed(message).localizedDescription == message)
        #expect(ClaudeUsageError.parseFailed(message).localizedDescription == message)
        #expect(ClaudeUsageError.parseFailed("No quota rows.").localizedDescription ==
            "Could not parse Claude usage: No quota rows.")
    }

    @Test
    func `background probes reuse status identity until a user refresh`() async throws {
        let fixture = try self.makeFakeClaude(
            panel: #"printf 'Current session\r\n13%% used\r\nCurrent week (all models)\r\n2%% used\r\n'"#)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data(#"{"oauthAccount":{"accountUuid":"synthetic-account"}}"#.utf8)
            .write(to: fixture.directory.appendingPathComponent(".config.json"))
        let probe = ClaudeStatusProbe(claudeBinary: fixture.binary.path, timeout: 8, environment: fixture.environment)

        let snapshots = try await ClaudeStatusProbe.$statusIdentityStoreOverrideForTesting.withValue(
            ClaudeStatusProbe.StatusIdentityStore())
        {
            try await ClaudeCLISession.withIsolatedSessionForTesting {
                var snapshots: [ClaudeStatusSnapshot] = []
                for interaction in [ProviderInteraction.background, .background, .userInitiated] {
                    try await snapshots.append(ProviderInteractionContext.$current.withValue(interaction) {
                        try await probe.fetch()
                    })
                }
                return snapshots
            }
        }

        let commands = try String(contentsOf: fixture.directory.appendingPathComponent("commands.log"), encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(commands.filter { $0 == "/usage" }.count == 3)
        #expect(commands.filter { $0 == "/status" }.count == 2)
        #expect(snapshots.map(\.accountEmail) == Array(repeating: "user@example.com", count: 3))
        #expect(snapshots.first?.loginMethod != nil)
        #expect(Set(snapshots.map(\.loginMethod)).count == 1)
    }

    @Test(arguments: [
        ("Login method: Claude Max Account\nOrganization: Example\nEmail: user@example.com", true),
        ("Login method: Claude Max Account\nAccount: user@example.com", true),
        ("Login method: Claude Max Account\nOrganization: Example", false),
        ("Email: user@example.com", false),
        ("Login method: Claude Max Account\nEmail:\nSession ID: abc\nContact: ops@example.com", false),
    ])
    func `status capture stops once identity is drawn`(screen: String, expected: Bool) {
        let normalized = String(screen.lowercased().filter { !$0.isWhitespace })
        #expect(ClaudeStatusProbe.statusCaptureHasIdentity(normalized) == expected)
    }

    private func makeFakeClaude(panel: String) throws -> (
        directory: URL,
        binary: URL,
        environment: [String: String])
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-capture-timing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("fake-claude")
        let script = """
        #!/bin/bash
        /bin/stty raw -echo -icrnl
        printf '────\\r\\n❯ \\r\\n────\\r\\n  ? for shortcuts\\r\\n'
        command=''
        while IFS= read -r -n 1 key; do
          case "$key" in
            # read -n 1 reports a newline as an empty key.
            $'\\r'|'')
              if [[ -n "$command" ]]; then printf '%s\\n' "$command" >> "$HOME/commands.log"; fi
              if [[ "$command" == /usage ]]; then
        \(panel)
              elif [[ "$command" == /status ]]; then
                printf 'Login method: Claude Max Account\\r\\nEmail: user@example.com\\r\\n'
              fi
              command=''
              ;;
            $'\\e') command='' ;;
            *) command+="$key" ;;
          esac
        done
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let environment = [
            "HOME": directory.path,
            "CLAUDE_CONFIG_DIR": directory.path,
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": directory.path,
            "BARS_DISABLE_CLAUDE_WATCHDOG": "1",
        ]
        return (directory, binary, environment)
    }
}
