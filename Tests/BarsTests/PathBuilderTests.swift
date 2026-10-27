import Foundation
import Testing
@testable import Bars
@testable import BarsCore

struct PathBuilderTests {
    @Test
    func `merges login shell path when available`() {
        let seeded = PathBuilder.effectivePATH(
            purposes: [.rpc],
            env: ["PATH": "/custom/bin:/usr/bin"],
            loginPATH: ["/login/bin", "/login/alt"])
        #expect(seeded == "/login/bin:/login/alt:/custom/bin:/usr/bin")
    }

    @Test
    func `falls back to existing path when no login path`() {
        let seeded = PathBuilder.effectivePATH(
            purposes: [.tty],
            env: ["PATH": "/custom/bin:/usr/bin"],
            loginPATH: nil)
        #expect(seeded == "/custom/bin:/usr/bin")
    }

    @Test
    func `uses fallback when no path available`() {
        let seeded = PathBuilder.effectivePATH(
            purposes: [.tty],
            env: [:],
            loginPATH: nil)
        #expect(seeded == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test
    func `debug snapshot async matches sync`() async {
        let env = [
            "CODEX_CLI_PATH": "/usr/bin/true",
            "CLAUDE_CLI_PATH": "/usr/bin/true",
            "GEMINI_CLI_PATH": "/usr/bin/true",
            "PATH": "/usr/bin:/bin",
        ]
        let sync = PathBuilder.debugSnapshot(purposes: [.rpc], env: env, home: "/tmp")
        let async = await PathBuilder.debugSnapshotAsync(purposes: [.rpc], env: env, home: "/tmp")
        #expect(async == sync)
    }

    @Test
    func `login shell cache retries after timed out nil capture`() async {
        let capture = LoginShellPathCaptureStub([
            nil,
            ["/login/bin", "/usr/bin"],
        ])

        let cache = LoginShellPathCache { _, _ in capture.next() }
        let firstResult: [String]? = await withCheckedContinuation { continuation in
            cache.captureOnce(shell: "/unused", timeout: 0.01) { result in
                continuation.resume(returning: result)
            }
        }

        #expect(firstResult == nil)
        #expect(cache.current == nil)

        let recovered = cache.currentOrCapture(shell: "/unused", timeout: 2.0)
        #expect(recovered == ["/login/bin", "/usr/bin"])
        #expect(cache.current == ["/login/bin", "/usr/bin"])
        #expect(capture.callCount == 2)
    }

    @Test
    func `shell runner drains noisy stdout and stderr`() throws {
        let script = """
        i=0
        while [ "$i" -lt 4000 ]; do
          printf 'out-%04d\\n' "$i"
          printf 'err-%04d\\n' "$i" >&2
          i=$((i + 1))
        done
        printf '__BARS_DONE__\\n'
        """
        let data = try #require(ShellCommandLocator.test_runShellCommand(
            shell: "/bin/sh",
            arguments: ["-c", script],
            timeout: 4.0))
        let output = try #require(String(data: data, encoding: .utf8))

        #expect(output.contains("out-3999"))
        #expect(output.contains("__BARS_DONE__"))
    }

    @Test
    func `shell runner terminates background children after normal exit`() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("bars-shell-runner-\(UUID().uuidString)")
            .path
        let escapedMarker = Self.shellSingleQuoted(marker)
        let script = """
        (
          trap '' HUP TERM
          touch \(escapedMarker)
          while :; do sleep 1; done
        ) &
        printf '%s\\n' "$!"
        """
        let data = try #require(ShellCommandLocator.test_runShellCommand(
            shell: "/bin/sh",
            arguments: ["-c", script],
            timeout: 2.0))
        let pidText = try #require(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
        let pid = try #require(pid_t(pidText))

        defer {
            kill(pid, SIGKILL)
            try? FileManager.default.removeItem(atPath: marker)
        }

        let deadline = Date().addingTimeInterval(2.0)
        while kill(pid, 0) == 0, Date() < deadline {
            usleep(50000 as useconds_t)
        }

        #expect(kill(pid, 0) != 0)
    }

    #if os(macOS)

    #endif

    @Test
    func `resolves claude from interactive shell`() {
        let fm = MockFileManager(executables: ["/shell/bin/claude"])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { tool, shell, timeout, fileManager in
            #expect(tool == "claude")
            #expect(shell == "/bin/zsh")
            #expect(timeout == 2.0)
            _ = fileManager
            return "/shell/bin/claude"
        }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            fileManager: fm,
            home: "/home/test")
        #expect(resolved == "/shell/bin/claude")
    }

    @Test
    func `resolves claude from login path`() {
        let fm = MockFileManager(executables: ["/login/bin/claude"])
        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["PATH": "/env/bin"],
            loginPATH: ["/login/bin"],
            fileManager: fm,
            home: "/home/test")
        #expect(resolved == "/login/bin/claude")
    }

    @Test
    func `resolves claude from alias when other lookups fail`() {
        let aliasPath = "/home/test/.claude/local/bin/claude"
        let fm = MockFileManager(executables: [aliasPath])
        var aliasCalled = false
        let aliasResolver: (String, String?, TimeInterval, FileManager, String)
            -> String? = { tool, shell, timeout, _, home in
                aliasCalled = true
                #expect(tool == "claude")
                #expect(shell == "/bin/zsh")
                #expect(timeout == 2.0)
                #expect(home == "/home/test")
                return aliasPath
            }
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in
            nil
        }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/home/test")

        #expect(aliasCalled)
        #expect(resolved == aliasPath)
    }

    @Test
    func `resolves claude from well-known cmux path when shell lookups fail`() {
        let cmuxPath = "/Applications/cmux.app/Contents/Resources/bin/claude"
        let fm = MockFileManager(executables: [cmuxPath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == cmuxPath)
    }

    @Test
    func `resolves claude from well-known home dir path`() {
        let homePath = "/Users/test/.claude/bin/claude"
        let fm = MockFileManager(executables: [homePath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == homePath)
    }

    @Test
    func `resolves claude from native installer path`() {
        let nativePath = "/Users/test/.local/bin/claude"
        let fm = MockFileManager(executables: [nativePath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == nativePath)
    }

    @Test
    func `prefers migrated local claude path over legacy home dir path`() {
        let migratedPath = "/Users/test/.claude/local/claude"
        let legacyPath = "/Users/test/.claude/bin/claude"
        let fm = MockFileManager(executables: [migratedPath, legacyPath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == migratedPath)
    }

    @Test
    func `prefers user managed well-known path over cmux path`() {
        let homePath = "/Users/test/.claude/bin/claude"
        let cmuxPath = "/Applications/cmux.app/Contents/Resources/bin/claude"
        let fm = MockFileManager(executables: [homePath, cmuxPath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == homePath)
    }

    @Test
    func `prefers homebrew arm path over usr local fallback`() {
        let fm = MockFileManager(executables: [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == "/opt/homebrew/bin/claude")
    }

    @Test
    func `prefers well-known paths over interactive shell lookup`() {
        let shellPath = "/custom/bin/claude"
        let cmuxPath = "/Applications/cmux.app/Contents/Resources/bin/claude"
        let fm = MockFileManager(executables: [shellPath, cmuxPath])
        var shellLookupCalled = false
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in
            shellLookupCalled = true
            return shellPath
        }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            fileManager: fm,
            home: "/Users/test")
        #expect(!shellLookupCalled)
        #expect(resolved == cmuxPath)
    }

    @Test
    func `skips alias when command V resolves`() {
        let path = "/shell/bin/claude"
        let fm = MockFileManager(executables: [path])
        var aliasCalled = false
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in
            aliasCalled = true
            return "/alias/claude"
        }
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in
            path
        }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/home/test")

        #expect(!aliasCalled)
        #expect(resolved == path)
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private final class LoginShellPathCaptureStub: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [[String]?]
    private var callCountStorage = 0

    var callCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.callCountStorage
    }

    init(_ results: [[String]?]) {
        self.results = results
    }

    func next() -> [String]? {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.callCountStorage += 1
        return self.results.isEmpty ? nil : self.results.removeFirst()
    }
}

private final class MockFileManager: FileManager {
    private let executables: Set<String>

    init(executables: Set<String>) {
        self.executables = executables
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        self.executables.contains(path)
    }
}
