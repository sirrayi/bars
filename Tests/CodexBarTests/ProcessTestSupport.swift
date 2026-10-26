import Foundation

enum KiroProcessTestSupport {
    private struct WaitTimeout: LocalizedError {
        let description: String
        let timeout: Duration

        var errorDescription: String? {
            "Timed out after \(self.timeout) waiting for \(self.description)"
        }
    }

    /// This bounds fixture setup only. Tests that exercise production timeout behavior pass their own exact budgets.
    static let fixtureSetupTimeout: Duration = .seconds(20)
    static let fixtureAccountTimeout: TimeInterval = 15

    // MARK: - Fixture lifetime

    /// Maximum lifetime of an intentionally held fixture, above every test's own wait.
    static let fixtureHoldLimit: TimeInterval = 120

    /// Python expression that blocks until `ownerPID` exits or `timeout` seconds pass.
    ///
    /// It returns an exit event or an empty list on timeout; an already-reaped owner raises ESRCH,
    /// which also ends the fixture. SIGTERM-ignoring fixtures use it instead of
    /// waiting forever, so they cannot outlive an interrupted test run whose cleanup `defer` never
    /// runs (#4567). The owner defaults to the test process itself; watching a fixture's immediate
    /// parent would end the hold early. Requires `import select` and contains no quotes, so it can be
    /// embedded in Python and shell string literals.
    static func pythonOwnerExitWait(timeout: TimeInterval, ownerPID: String = String(getpid())) -> String {
        "select.kqueue().control([select.kevent(\(ownerPID), select.KQ_FILTER_PROC, " +
            "select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 1, \(timeout))"
    }

    /// Python statement that holds a fixture until its owner exits, bounded by `fixtureHoldLimit`.
    static func pythonOwnerBoundedHold(ownerPID: String = String(getpid())) -> String {
        "import select; " + self.pythonOwnerExitWait(timeout: self.fixtureHoldLimit, ownerPID: ownerPID)
    }

    /// Shell command that replaces the current (sub)shell with `pythonOwnerBoundedHold`.
    /// Ignored signals, the PID and the process group are preserved across `exec`.
    static func shellOwnerBoundedHold(ownerPID: String = String(getpid())) -> String {
        "exec /usr/bin/python3 -c \"\(self.pythonOwnerBoundedHold(ownerPID: ownerPID))\""
    }

    static func waitForFile(
        _ url: URL,
        timeout: Duration = fixtureSetupTimeout) async throws
    {
        _ = try await self.wait(
            for: "fixture file \(url.path)",
            timeout: timeout)
        {
            FileManager.default.fileExists(atPath: url.path) ? true : nil
        }
    }

    static func waitForPID(
        in url: URL,
        timeout: Duration = fixtureSetupTimeout) async throws -> pid_t
    {
        try await self.wait(
            for: "a valid PID in fixture file \(url.path)",
            timeout: timeout)
        {
            self.readPID(from: url)
        }
    }

    static func waitForExit(
        of pid: pid_t,
        timeout: Duration,
        description: String) async throws
    {
        try await self.waitForExit(of: [pid], timeout: timeout, description: description)
    }

    static func waitForExit(
        of pids: [pid_t],
        timeout: Duration,
        description: String) async throws
    {
        _ = try await self.wait(for: description, timeout: timeout) {
            pids.allSatisfy { kill($0, 0) == -1 } ? true : nil
        }
    }

    static func readPID(from url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else {
            return nil
        }
        return pid
    }

    static func touch(_ url: URL) throws {
        let fileDescriptor = open(url.path, O_WRONLY | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        _ = close(fileDescriptor)
    }

    static func waitForCondition(
        _ description: String,
        timeout: Duration = fixtureSetupTimeout,
        condition: () -> Bool) async throws
    {
        _ = try await self.wait(for: description, timeout: timeout) {
            condition() ? true : nil
        }
    }

    private static func wait<Value>(
        for description: String,
        timeout: Duration,
        value: () -> Value?) async throws -> Value
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let value = value() {
                return value
            }
            guard clock.now < deadline else {
                throw WaitTimeout(description: description, timeout: timeout)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
