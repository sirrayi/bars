import Foundation

final class FutureModificationDateClamp: @unchecked Sendable {
    private let lock = NSLock()
    private var clampDate: Date?

    init(clampDate: Date? = nil) {
        self.clampDate = clampDate
    }

    func clamp(url _: URL, modifiedAt: Date, now: Date) -> Date {
        guard modifiedAt > now else { return modifiedAt }
        return self.lock.withLock {
            if let clampDate = self.clampDate {
                return min(clampDate, now)
            }
            self.clampDate = now
            return now
        }
    }
}

public struct LocalAgentSessionScanner: Sendable {
    typealias ProcessOutputProvider = @Sendable ([String: String]) async -> String
    typealias CWDProvider = @Sendable ([Int32], [String: String]) async -> [Int32: String]

    private struct ScanContext: Sendable {
        let homeDirectory: URL
        let host: String
        let now: Date
    }

    public let config: SessionScanConfig
    private let futureModificationDateClamp = FutureModificationDateClamp()
    private let processOutputProvider: ProcessOutputProvider?
    private let cwdProvider: CWDProvider?
    private let directoryScanStartedAt: @Sendable () -> Date
    private let didVisitDirectoryEntry: (@Sendable () -> Void)?

    public init(config: SessionScanConfig = SessionScanConfig()) {
        self.init(config: config, processOutputProvider: nil, cwdProvider: nil)
    }

    init(
        config: SessionScanConfig = SessionScanConfig(),
        processOutputProvider: ProcessOutputProvider?,
        cwdProvider: CWDProvider?,
        directoryScanStartedAt: @escaping @Sendable () -> Date = Date.init,
        didVisitDirectoryEntry: (@Sendable () -> Void)? = nil)
    {
        self.config = config
        self.processOutputProvider = processOutputProvider
        self.cwdProvider = cwdProvider
        self.directoryScanStartedAt = directoryScanStartedAt
        self.didVisitDirectoryEntry = didVisitDirectoryEntry
    }

    @concurrent
    public func scan(
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeFileOnlySessions: Bool = true) async -> [AgentSession]
    {
        let allProcesses = await self.processRecords(environment: environment)
        let processes = Array(AgentSessionCorrelation.newestProcessesFirst(
            AgentPSOutputParser.agentProcesses(from: allProcesses))
            .prefix(max(0, self.config.maxProcessCount)))
        guard Self.shouldScanSessionMetadata(
            hasAgentProcesses: !processes.isEmpty,
            includeFileOnlySessions: includeFileOnlySessions)
        else { return [] }
        let homeDirectory = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let cwdByPID = await self.cwdByPID(processes.map(\.pid), environment: environment)
        var directoryBudget = DirectoryMetadataScanBudget(
            maxEntryCount: self.config.maxDirectoryEntryCount,
            maxDepth: self.config.maxDirectoryDepth,
            timeLimit: includeFileOnlySessions
                ? self.config.directoryScanBudget
                : min(self.config.directoryScanBudget, self.config.adaptiveDirectoryScanBudget),
            startedAt: self.directoryScanStartedAt(),
            didVisitEntry: self.didVisitDirectoryEntry)
        return self.sessions(
            processes: processes,
            cwdByPID: cwdByPID,
            context: ScanContext(
                homeDirectory: homeDirectory,
                host: ProcessInfo.processInfo.hostName,
                now: now),
            directoryBudget: &directoryBudget)
    }

    public static func shouldScanSessionMetadata(
        hasAgentProcesses: Bool,
        includeFileOnlySessions: Bool) -> Bool
    {
        hasAgentProcesses || includeFileOnlySessions
    }

    private func sessions(
        processes: [AgentProcessRecord],
        cwdByPID: [Int32: String],
        context: ScanContext,
        directoryBudget: inout DirectoryMetadataScanBudget) -> [AgentSession]
    {
        var sessions: [AgentSession] = []
        let claudeProcesses = processes.filter { AgentPSOutputParser.provider(for: $0) == .claude }
        let claudeCWDs = Set(claudeProcesses.compactMap { cwdByPID[$0.pid] })
        var claudeTranscriptsByCWD: [String: [ClaudeSessionProjectMapper.Transcript]] = [:]
        for cwd in claudeCWDs {
            claudeTranscriptsByCWD[cwd] = ClaudeSessionProjectMapper.transcripts(
                cwd: cwd,
                homeDirectory: context.homeDirectory,
                limit: self.config.maxClaudeTranscriptCountPerProject,
                now: context.now,
                budget: &directoryBudget,
                clampModificationDate: self.futureModificationDateClamp.clamp)
        }
        let claudeTranscripts = AgentSessionCorrelation.assignClaudeTranscripts(
            processes: claudeProcesses,
            cwdByPID: cwdByPID,
            transcriptsByCWD: claudeTranscriptsByCWD)

        for process in claudeProcesses {
            let cwd = cwdByPID[process.pid]
            let transcript = claudeTranscripts[process.pid]
            let modifiedAt = transcript?.modifiedAt
            sessions.append(AgentSession(
                id: transcript?.url.deletingPathExtension().lastPathComponent ?? "pid:\(process.pid)",
                provider: .claude,
                source: AgentPSOutputParser.source(for: process),
                state: self.config.state(lastActivityAt: modifiedAt, now: context.now, hasLiveProcess: true),
                pid: process.pid,
                cwd: cwd,
                projectName: cwd.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent },
                sessionName: nil,
                startedAt: process.startedAt,
                lastActivityAt: modifiedAt,
                transcriptPath: transcript?.url.path,
                host: context.host))
        }

        var seen = Set<String>()
        return sessions
            .sorted { lhs, rhs in
                if lhs.state != rhs.state {
                    return lhs.state == .active
                }
                return (lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast) >
                    (rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast)
            }
            .filter { seen.insert("\($0.host):\($0.id)").inserted }
    }

    private func processRecords(environment: [String: String]) async -> [AgentProcessRecord] {
        if let processOutputProvider = self.processOutputProvider {
            return await AgentPSOutputParser.parse(processOutputProvider(environment))
        }
        #if canImport(Darwin)
        return DarwinProcessEnumerator.allPIDs().compactMap { pid in
            Self.darwinProcessRecord(pid: pid)
        }
        #else
        return await AgentPSOutputParser.parse(self.processOutput(environment: environment))
        #endif
    }

    #if canImport(Darwin)
    /// Builds a process record from libproc data. `proc_pidpath` fails with ENOENT once an updater deletes the
    /// running binary (for example the old package directory after a Claude Code update), so argv is preferred
    /// and the executable path is only the fallback command when argv is unavailable.
    static func darwinProcessRecord(
        pid: Int32,
        bsdInfo: (Int32) -> (ppid: Int32, startTime: Date)? = DarwinProcessEnumerator.bsdInfo,
        processArguments: (Int32) -> [String]? = DarwinProcessEnumerator.arguments,
        executablePath: (Int32) -> String? = DarwinProcessEnumerator.executablePath) -> AgentProcessRecord?
    {
        guard let bsdInfo = bsdInfo(pid) else { return nil }
        let arguments = processArguments(pid)
        guard let command = arguments?.joined(separator: " ") ?? executablePath(pid) else { return nil }
        return AgentProcessRecord(
            pid: pid,
            ppid: bsdInfo.ppid,
            startedAt: bsdInfo.startTime,
            command: command,
            arguments: arguments)
    }
    #endif

    #if !canImport(Darwin)
    private func processOutput(environment: [String: String]) async -> String {
        let binary = ["/bin/ps", "/usr/bin/ps"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let binary,
              let result = try? await SubprocessRunner.run(
                  binary: binary,
                  arguments: ["-axo", "pid=,ppid=,lstart=,command="],
                  environment: environment,
                  timeout: 5,
                  label: "agent session process scan")
        else { return "" }
        return result.stdout
    }
    #endif

    private func cwdByPID(_ pids: [Int32], environment: [String: String]) async -> [Int32: String] {
        if let cwdProvider = self.cwdProvider { return await cwdProvider(pids, environment) }
        guard !pids.isEmpty else { return [:] }
        #if canImport(Darwin)
        return Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
            DarwinProcessEnumerator.currentWorkingDirectory(pid: pid).map { (pid, $0) }
        })
        #else
        if let lsof = self.findExecutable("lsof", environment: environment) {
            let joinedPIDs = pids.map(String.init).joined(separator: ",")
            if let result = try? await SubprocessRunner.run(
                binary: lsof,
                arguments: ["-a", "-d", "cwd", "-Fn", "-p", joinedPIDs],
                environment: environment,
                timeout: 5,
                acceptsNonZeroExit: true,
                label: "agent session cwd scan")
            {
                return LSOFCWDOutputParser.parse(result.stdout)
            }
        }

        return Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
            let path = "/proc/\(pid)/cwd"
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
            return (pid, destination)
        })
        #endif
    }

    private func findExecutable(_ name: String, environment: [String: String]) -> String? {
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        return BinaryLocator.find(name, in: path.split(separator: ":").map(String.init), fileManager: .default)
    }
}
