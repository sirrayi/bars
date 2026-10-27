import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if os(macOS)
import Security
#endif

#if os(Linux)
@_silgen_name("pipe2")
private func linuxPipe2(_ pipeDescriptors: UnsafeMutablePointer<Int32>, _ flags: Int32) -> Int32
#endif

public enum PathPurpose: Hashable, Sendable {
    case rpc
    case tty
    case nodeTooling
}

public struct PathDebugSnapshot: Equatable, Sendable {
    public let claudeBinary: String?
    public let effectivePATH: String
    public let loginShellPATH: String?

    public static let empty = PathDebugSnapshot(
        claudeBinary: nil,
        effectivePATH: "",
        loginShellPATH: nil)

    public init(
        claudeBinary: String?,
        effectivePATH: String,
        loginShellPATH: String?)
    {
        self.claudeBinary = claudeBinary
        self.effectivePATH = effectivePATH
        self.loginShellPATH = loginShellPATH
    }
}

public enum BinaryLocator {
    public static func resolveClaudeBinary(
        env: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        commandV: (String, String?, TimeInterval, FileManager) -> String? = ShellCommandLocator.commandV,
        aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = ShellCommandLocator
            .resolveAlias,
        fileManager: FileManager = .default,
        home: String = NSHomeDirectory()) -> String?
    {
        // Provider-specific by design: This named resolver supplies Claude's actual CLI executable name.
        self.resolveBinary(
            name: "claude",
            overrideKey: "CLAUDE_CLI_PATH",
            env: env,
            loginPATH: loginPATH,
            commandV: commandV,
            aliasResolver: aliasResolver,
            wellKnownPaths: self.claudeWellKnownPaths(home: home),
            fileManager: fileManager,
            home: home)
    }

    /// Well-known installation paths for the Claude CLI binary.
    /// Covers Anthropic's native installer (`~/.local/bin`), the `claude migrate-installer`
    /// self-updating location (`~/.claude/local`), the legacy per-user installer
    /// (`~/.claude/bin`), Homebrew, and the macOS Terminal installer (cmux.app).
    static func claudeWellKnownPaths(home: String) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.claude/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/Applications/cmux.app/Contents/Resources/bin/claude",
        ]
    }

    // swiftlint:disable function_parameter_count
    static func resolveBinary(
        name: String,
        overrideKey: String,
        env: [String: String],
        loginPATH: [String]?,
        commandV: (String, String?, TimeInterval, FileManager) -> String?,
        aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String?,
        wellKnownPaths: [String] = [],
        launchCandidateFilter: (String, FileManager) -> Bool = { _, _ in true },
        fileManager: FileManager,
        home: String) -> String?
    {
        // swiftlint:enable function_parameter_count
        // 1) Explicit override
        if let override = env[overrideKey], fileManager.isExecutableFile(atPath: override) {
            return override
        }

        // 2) Login-shell PATH (captured once per launch)
        if let loginPATH,
           let pathHit = self.find(
               name,
               in: loginPATH,
               fileManager: fileManager,
               launchCandidateFilter: launchCandidateFilter)
        {
            return pathHit
        }

        // 3) Existing PATH
        if let existingPATH = env["PATH"],
           let pathHit = self.find(
               name,
               in: existingPATH.split(separator: ":").map(String.init),
               fileManager: fileManager,
               launchCandidateFilter: launchCandidateFilter)
        {
            return pathHit
        }

        // 4) Well-known installation paths (e.g. Homebrew, cmux.app bundle, ~/.claude/bin).
        // Prefer these before shell probing to avoid running interactive shell init for common installs.
        for candidate in wellKnownPaths
            where fileManager.isExecutableFile(atPath: candidate) && launchCandidateFilter(candidate, fileManager)
        {
            return candidate
        }

        // 5) Interactive login shell lookup (captures nvm/fnm/mise paths from .zshrc/.bashrc)
        if let shellHit = commandV(name, env["SHELL"], 2.0, fileManager),
           fileManager.isExecutableFile(atPath: shellHit),
           launchCandidateFilter(shellHit, fileManager)
        {
            return shellHit
        }

        // 5b) Alias fallback (login shell); only attempt after all standard lookups fail.
        if let aliasHit = aliasResolver(name, env["SHELL"], 2.0, fileManager, home),
           aliasHit.hasPrefix("/"),
           fileManager.isExecutableFile(atPath: aliasHit),
           launchCandidateFilter(aliasHit, fileManager)
        {
            return aliasHit
        }

        // 6) Minimal fallback
        return self.find(
            name,
            in: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"],
            fileManager: fileManager,
            launchCandidateFilter: launchCandidateFilter)
    }

    static func find(
        _ binary: String,
        in paths: [String],
        fileManager: FileManager,
        launchCandidateFilter: (String, FileManager) -> Bool = { _, _ in true }) -> String?
    {
        if binary.contains("/") {
            let path = URL(fileURLWithPath: binary).standardizedFileURL.path
            return fileManager.isExecutableFile(atPath: path) && launchCandidateFilter(path, fileManager)
                ? path : nil
        }
        guard !binary.isEmpty else { return nil }
        for path in PathBuilder.searchDirectories(paths) {
            let candidate = "\(path.hasSuffix("/") ? String(path.dropLast()) : path)/\(binary)"
            if fileManager.isExecutableFile(atPath: candidate), launchCandidateFilter(candidate, fileManager) {
                return candidate
            }
        }
        return nil
    }
}

public enum ShellCommandLocator {
    #if canImport(Darwin)
    private static let shellSpawnFlags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
    #else
    private static let shellSpawnFlags: Int16 = 0x80 // glibc/musl POSIX_SPAWN_SETSID.
    #endif
    private static let shellSpawnLock = NSLock()

    static func test_runShellCommand(
        shell: String,
        arguments: [String],
        timeout: TimeInterval) -> Data?
    {
        self.runShellCommand(shell: shell, arguments: arguments, timeout: timeout)
    }

    static func test_makeCloseOnExecPipe() -> (read: Int32, write: Int32)? {
        self.makeCloseOnExecPipe()
    }

    static var test_shellSpawnFlags: Int16 {
        self.shellSpawnFlags
    }

    public static func commandV(
        _ tool: String,
        _ shell: String?,
        _ timeout: TimeInterval,
        _ fileManager: FileManager) -> String?
    {
        let text = self.runShellCapture(shell, timeout, "command -v \(tool)")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }

        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines.reversed() where line.hasPrefix("/") {
            let path = line
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    public static func resolveAlias(
        _ tool: String,
        _ shell: String?,
        _ timeout: TimeInterval,
        _ fileManager: FileManager,
        _ home: String) -> String?
    {
        let command = "alias \(tool) 2>/dev/null; type -a \(tool) 2>/dev/null"
        guard let text = self.runShellCapture(shell, timeout, command) else { return nil }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let aliasPath = self.parseAliasPath(lines, tool: tool, home: home, fileManager: fileManager) {
            return aliasPath
        }

        for line in lines {
            if let path = self.extractPathCandidate(line: line, tool: tool, home: home),
               fileManager.isExecutableFile(atPath: path)
            {
                return path
            }
        }

        return nil
    }

    private static func makeCloseOnExecPipe() -> (read: Int32, write: Int32)? {
        var fds: (read: Int32, write: Int32) = (-1, -1)
        #if os(Linux)
        // Glibc and Musl export pipe2, but their Swift modules do not consistently declare it.
        guard withUnsafeMutablePointer(to: &fds, {
            $0.withMemoryRebound(to: Int32.self, capacity: 2) { linuxPipe2($0, O_CLOEXEC) == 0 }
        }) else { return nil }
        #else
        guard withUnsafeMutablePointer(to: &fds, {
            $0.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) == 0 }
        }) else { return nil }

        for fd in [fds.read, fds.write] {
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                close(fds.read)
                close(fds.write)
                return nil
            }
        }
        #endif
        return fds
    }

    /// Runs a shell command, draining both stdout and stderr concurrently so that
    /// verbose shell init scripts (oh-my-zsh, nvm, pyenv, etc.) cannot deadlock on
    /// a full pipe buffer.  The child is launched via `posix_spawn` with
    /// `POSIX_SPAWN_SETSID` so it cannot take ownership of the caller's controlling
    /// terminal. The new session also makes the child its own process-group leader;
    /// cleanup tracks both that group and helpers retaining the command's output pipes.
    fileprivate static func runShellCommand(
        shell: String,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Data?
    {
        // Darwin needs a lock around raw descriptor creation, close-on-exec flagging,
        // and spawn. Linux creates close-on-exec descriptors atomically with pipe2.
        self.shellSpawnLock.lock()
        var shellSpawnLockHeld = true
        defer {
            if shellSpawnLockHeld {
                self.shellSpawnLock.unlock()
            }
        }

        // Pipes for stdout/stderr.  stdin is redirected from /dev/null in the child
        // via posix_spawn_file_actions_addopen below. Close-on-exec prevents a
        // concurrently spawned probe from retaining these descriptors and being
        // mistaken for one of this probe's output holders during cleanup.
        guard let stdoutFds = self.makeCloseOnExecPipe() else { return nil }
        guard let stderrFds = self.makeCloseOnExecPipe() else {
            close(stdoutFds.read); close(stdoutFds.write)
            return nil
        }

        // Build file actions: redirect stdin from /dev/null, dup pipe write ends to
        // fds 1 and 2, and close every pipe fd in the child.  The init pattern
        // differs between platforms because the typedef is an opaque pointer on
        // Darwin and a struct on Linux C modules.
        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t?
        #else
        var fileActions = posix_spawn_file_actions_t()
        #endif
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            close(stdoutFds.read); close(stdoutFds.write)
            close(stderrFds.read); close(stderrFds.write)
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutFds.write, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderrFds.write, 2)
        posix_spawn_file_actions_addclose(&fileActions, stdoutFds.read)
        posix_spawn_file_actions_addclose(&fileActions, stdoutFds.write)
        posix_spawn_file_actions_addclose(&fileActions, stderrFds.read)
        posix_spawn_file_actions_addclose(&fileActions, stderrFds.write)

        // Build attributes: detach the child into a new session before exec. This
        // prevents interactive shell startup from changing the caller's foreground
        // process group while retaining a stable process group for cleanup.
        #if canImport(Darwin)
        var attr: posix_spawnattr_t?
        #else
        var attr = posix_spawnattr_t()
        #endif
        guard posix_spawnattr_init(&attr) == 0 else {
            close(stdoutFds.read); close(stdoutFds.write)
            close(stderrFds.read); close(stderrFds.write)
            return nil
        }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawnattr_setflags(&attr, self.shellSpawnFlags) == 0 else {
            close(stdoutFds.read); close(stdoutFds.write)
            close(stderrFds.read); close(stderrFds.write)
            return nil
        }

        // Build argv (argv[0] is conventionally the executable path).
        var cArgs: [UnsafeMutablePointer<CChar>?] = []
        cArgs.append(strdup(shell))
        for arg in arguments {
            cArgs.append(strdup(arg))
        }
        cArgs.append(nil)
        defer {
            for p in cArgs {
                if let p {
                    free(p)
                }
            }
        }

        // Inherit the parent environment.  Build a NULL-terminated `KEY=VALUE`
        // array since `extern char **environ` isn't directly visible from Swift.
        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        var environment = environment
        environment["PATH"] = PathBuilder.effectivePATH(purposes: [.tty], env: environment, loginPATH: nil)
        for (key, value) in environment {
            cEnv.append(strdup("\(key)=\(value)"))
        }
        cEnv.append(nil)
        defer {
            for p in cEnv {
                if let p {
                    free(p)
                }
            }
        }

        var pid: pid_t = 0
        let spawnResult = shell.withCString { execPath in
            posix_spawn(&pid, execPath, &fileActions, &attr, cArgs, cEnv)
        }

        // Close the write ends in the parent so EOF will arrive on the read ends
        // once every descendant in the process group also closes them.
        close(stdoutFds.write)
        close(stderrFds.write)
        self.shellSpawnLock.unlock()
        shellSpawnLockHeld = false

        guard spawnResult == 0 else {
            close(stdoutFds.read); close(stderrFds.read)
            return nil
        }

        // Retain one overflow byte so discovery rejects oversized output instead of parsing a truncated path.
        let maxOutputBytes = ProcessPipeCapture.defaultMaxBytes
        let stdoutCapture = ProcessPipeCapture(
            handle: FileHandle(fileDescriptor: stdoutFds.read, closeOnDealloc: true),
            maxBytes: maxOutputBytes + 1)
        let stderrCapture = ProcessPipeCapture(
            handle: FileHandle(fileDescriptor: stderrFds.read, closeOnDealloc: true),
            maxBytes: 0)

        // Snapshot pipe identities before the readers can reach EOF and close their descriptors.
        let process = SpawnedProcessGroup.adopt(
            pid: pid,
            outputFileDescriptors: [stdoutFds.read, stderrFds.read])
        stdoutCapture.start()
        stderrCapture.start()
        defer {
            stdoutCapture.stop()
            stderrCapture.stop()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(10000)
        }

        if process.isRunning {
            process.terminateSynchronously()
            return nil
        }

        // Normal completion — clean up background children spawned by shell init,
        // including session-escaped helpers that still hold our output pipes open.
        process.terminateSynchronously()

        let data = stdoutCapture.finishSynchronously(timeout: 1)
        guard stdoutCapture.reachedEOF, data.count <= maxOutputBytes else { return nil }
        return data
    }

    private static func runShellCapture(_ shell: String?, _ timeout: TimeInterval, _ command: String) -> String? {
        let shellPath = (shell?.isEmpty == false) ? shell! : "/bin/zsh"
        let isCI = ["1", "true"].contains(ProcessInfo.processInfo.environment["CI"]?.lowercased())
        // Interactive login shell to pick up PATH mutations from shell init (nvm/fnm/mise).
        // CI runners can have shell init hooks that emit missing CLI errors; avoid them in CI.
        let args = isCI ? ["-c", command] : ["-l", "-i", "-c", command]
        guard let data = runShellCommand(shell: shellPath, arguments: args, timeout: timeout) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func parseAliasPath(
        _ lines: [String],
        tool: String,
        home: String,
        fileManager: FileManager) -> String?
    {
        for line in lines {
            if line.hasPrefix("alias \(tool)=") {
                let value = line.replacingOccurrences(of: "alias \(tool)=", with: "")
                if let path = self.extractAliasExpansion(value, home: home),
                   fileManager.isExecutableFile(atPath: path)
                {
                    return path
                }
            }
            if line.lowercased().contains("aliased to") {
                if let range = line.range(of: "aliased to") {
                    let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if let path = self.extractAliasExpansion(String(value), home: home),
                       fileManager.isExecutableFile(atPath: path)
                    {
                        return path
                    }
                }
            }
        }
        return nil
    }

    private static func extractAliasExpansion(_ raw: String, home: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`"))
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        return self.expandPath(first, home: home)
    }

    private static func extractPathCandidate(line: String, tool: String, home: String) -> String? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        for token in tokens {
            let candidate = self.expandPath(token, home: home)
            if candidate.hasPrefix("/"),
               URL(fileURLWithPath: candidate).lastPathComponent == tool
            {
                return candidate
            }
        }
        return nil
    }

    private static func expandPath(_ raw: String, home: String) -> String {
        if raw == "~" {
            return home
        }
        if raw.hasPrefix("~/") {
            return home + String(raw.dropFirst())
        }
        return raw
    }
}

public enum PathBuilder {
    /// Relative and empty PATH entries depend on an untrusted invocation directory.
    static func searchDirectories(_ paths: [String]) -> [String] {
        paths.filter { $0.hasPrefix("/") }
    }

    public static func effectivePATH(
        purposes _: Set<PathPurpose>,
        env: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        home _: String = NSHomeDirectory()) -> String
    {
        var parts: [String] = []

        if let loginPATH, !loginPATH.isEmpty {
            parts.append(contentsOf: loginPATH)
        }

        if let existing = env["PATH"], !existing.isEmpty {
            parts.append(contentsOf: existing.split(separator: ":").map(String.init))
        }

        parts = self.searchDirectories(parts)
        if parts.isEmpty {
            parts.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        }

        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    public static func debugSnapshot(
        purposes: Set<PathPurpose>,
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()) -> PathDebugSnapshot
    {
        let login = LoginShellPathCache.shared.current
        let effective = self.effectivePATH(
            purposes: purposes,
            env: env,
            loginPATH: login,
            home: home)
        let claude = BinaryLocator.resolveClaudeBinary(env: env, loginPATH: login, home: home)
        let loginString = login?.joined(separator: ":")
        return PathDebugSnapshot(
            claudeBinary: claude,
            effectivePATH: effective,
            loginShellPATH: loginString)
    }

    public static func debugSnapshotAsync(
        purposes: Set<PathPurpose>,
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()) async -> PathDebugSnapshot
    {
        await Task.detached(priority: .userInitiated) {
            self.debugSnapshot(purposes: purposes, env: env, home: home)
        }.value
    }
}

enum LoginShellPathCapturer {
    static let defaultTimeout: TimeInterval = 6.0

    static func capture(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        timeout: TimeInterval = Self.defaultTimeout) -> [String]?
    {
        let shellPath = (shell?.isEmpty == false) ? shell! : "/bin/zsh"
        let isCI = ["1", "true"].contains(ProcessInfo.processInfo.environment["CI"]?.lowercased())
        let marker = "__BARS_PATH__"
        // Skip interactive login shells in CI to avoid noisy init hooks.
        let args = isCI
            ? ["-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
            : ["-l", "-i", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        guard let data = ShellCommandLocator.runShellCommand(
            shell: shellPath,
            arguments: args,
            timeout: timeout),
            let raw = String(data: data, encoding: .utf8),
            !raw.isEmpty
        else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let extracted = if let start = trimmed.range(of: marker),
                           let end = trimmed.range(of: marker, options: .backwards),
                           start.upperBound <= end.lowerBound
        {
            String(trimmed[start.upperBound..<end.lowerBound])
        } else {
            trimmed
        }

        let value = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.split(separator: ":").map(String.init)
    }
}

public final class LoginShellPathCache: @unchecked Sendable {
    public static let shared = LoginShellPathCache()

    private let lock = NSLock()
    private let capture: @Sendable (String?, TimeInterval) -> [String]?
    private var captured: [String]?
    private var isCapturing = false
    private var callbacks: [([String]?) -> Void] = []

    init(capture: @escaping @Sendable (String?, TimeInterval) -> [String]? = LoginShellPathCapturer.capture) {
        self.capture = capture
    }

    public var current: [String]? {
        self.lock.lock()
        let value = self.captured
        self.lock.unlock()
        return value
    }

    public func captureOnce(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        timeout: TimeInterval = 6.0,
        onFinish: (([String]?) -> Void)? = nil)
    {
        self.lock.lock()
        if let captured {
            self.lock.unlock()
            onFinish?(captured)
            return
        }

        if let onFinish {
            self.callbacks.append(onFinish)
        }

        if self.isCapturing {
            self.lock.unlock()
            return
        }

        self.isCapturing = true
        self.lock.unlock()

        let capture = self.capture
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = capture(shell, timeout)
            guard let self else { return }

            self.lock.lock()
            self.captured = result
            self.isCapturing = false
            let callbacks = self.callbacks
            self.callbacks.removeAll()
            self.lock.unlock()

            callbacks.forEach { $0(result) }
        }
    }

    public func currentOrCapture(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        timeout: TimeInterval = 6.0) -> [String]?
    {
        self.lock.lock()
        if let captured {
            self.lock.unlock()
            return captured
        }

        if self.isCapturing {
            let semaphore = DispatchSemaphore(value: 0)
            var callbackResult: [String]?
            self.callbacks.append { result in
                callbackResult = result
                semaphore.signal()
            }
            self.lock.unlock()
            let deadline = DispatchTime.now() + timeout
            _ = semaphore.wait(timeout: deadline)
            return callbackResult ?? self.current
        }

        self.isCapturing = true
        self.lock.unlock()

        let result = self.capture(shell, timeout)
        self.lock.lock()
        self.captured = result
        self.isCapturing = false
        let callbacks = self.callbacks
        self.callbacks.removeAll()
        self.lock.unlock()

        callbacks.forEach { $0(result) }
        return result
    }
}

/// Resolves bundle ownership from the executable, never argv[0] or the invocation directory.
enum ExecutableLocation {
    static func appBundleURL(containing executableURL: URL) -> URL? {
        let directory = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = directory.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard ["MacOS", "Helpers"].contains(directory.lastPathComponent),
              contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        return app
    }

    static func runningURL(bundle: Bundle) -> URL? {
        if let executableURL = bundle.executableURL {
            return executableURL
        }

        #if canImport(Darwin)
        var size: UInt32 = 0
        guard _NSGetExecutablePath(nil, &size) != 0 else { return nil }
        var buffer = [Int8](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: pathBytes, encoding: .utf8) else { return nil }
        return URL(fileURLWithPath: path)
        #elseif os(Linux)
        let path = "/proc/self/exe"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
        #else
        return nil
        #endif
    }
}
