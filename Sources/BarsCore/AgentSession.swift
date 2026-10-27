import Foundation

public struct AgentSession: Codable, Equatable, Sendable, Identifiable {
    public enum Provider: String, Codable, Sendable {
        case claude
    }

    public enum Source: String, Codable, Sendable {
        case cli
        case desktopApp
        case ide
        case unknown
    }

    public enum State: String, Codable, Sendable {
        case active
        case idle
    }

    public var id: String
    public var provider: Provider
    public var source: Source
    public var state: State
    public var pid: Int32?
    public var cwd: String?
    public var projectName: String?
    public var sessionName: String?
    public var startedAt: Date?
    public var lastActivityAt: Date?
    public var transcriptPath: String?
    public var host: String

    public init(
        id: String,
        provider: Provider,
        source: Source,
        state: State,
        pid: Int32?,
        cwd: String?,
        projectName: String?,
        sessionName: String? = nil,
        startedAt: Date?,
        lastActivityAt: Date?,
        transcriptPath: String?,
        host: String)
    {
        self.id = id
        self.provider = provider
        self.source = source
        self.state = state
        self.pid = pid
        self.cwd = cwd
        self.projectName = projectName
        self.sessionName = sessionName
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.transcriptPath = transcriptPath
        self.host = host
    }
}

public struct SessionScanConfig: Equatable, Sendable {
    public var activeWindow: TimeInterval
    public var fileOnlyWindow: TimeInterval
    public var maxProcessCount: Int
    public var maxClaudeTranscriptCountPerProject: Int
    public var maxDirectoryEntryCount: Int
    public var maxDirectoryDepth: Int
    public var directoryScanBudget: TimeInterval
    public var adaptiveDirectoryScanBudget: TimeInterval

    public init(
        activeWindow: TimeInterval = 120,
        fileOnlyWindow: TimeInterval = 30 * 60,
        maxProcessCount: Int = 64,
        maxClaudeTranscriptCountPerProject: Int = 64,
        maxDirectoryEntryCount: Int = 512,
        maxDirectoryDepth: Int = 1,
        directoryScanBudget: TimeInterval = 0.25,
        adaptiveDirectoryScanBudget: TimeInterval = 0.15)
    {
        self.activeWindow = activeWindow
        self.fileOnlyWindow = fileOnlyWindow
        self.maxProcessCount = maxProcessCount
        self.maxClaudeTranscriptCountPerProject = maxClaudeTranscriptCountPerProject
        self.maxDirectoryEntryCount = maxDirectoryEntryCount
        self.maxDirectoryDepth = maxDirectoryDepth
        self.directoryScanBudget = directoryScanBudget
        self.adaptiveDirectoryScanBudget = adaptiveDirectoryScanBudget
    }

    public func state(lastActivityAt: Date?, now: Date, hasLiveProcess: Bool) -> AgentSession.State {
        guard let lastActivityAt else { return hasLiveProcess ? .active : .idle }
        return now.timeIntervalSince(lastActivityAt) <= self.activeWindow ? .active : .idle
    }
}

struct DirectoryMetadataScanBudget {
    private var remainingEntryCount: Int
    let maxDepth: Int
    private let deadline: Date
    private let didVisitEntry: (@Sendable () -> Void)?

    init(
        maxEntryCount: Int,
        maxDepth: Int,
        timeLimit: TimeInterval,
        startedAt: Date = Date(),
        didVisitEntry: (@Sendable () -> Void)? = nil)
    {
        self.remainingEntryCount = max(0, maxEntryCount)
        self.maxDepth = max(0, maxDepth)
        self.deadline = startedAt.addingTimeInterval(max(0, timeLimit))
        self.didVisitEntry = didVisitEntry
    }

    mutating func files(
        in directory: URL,
        fileManager: FileManager = .default,
        clock: () -> Date = Date.init) -> [URL]
    {
        self.entries(in: directory, fileManager: fileManager, clock: clock)
            .compactMap { entry in entry.isDirectory ? nil : entry.url }
    }

    mutating func childDirectories(
        in directory: URL,
        fileManager: FileManager = .default,
        clock: () -> Date = Date.init) -> [URL]
    {
        self.entries(in: directory, fileManager: fileManager, clock: clock)
            .compactMap { entry in entry.isDirectory ? entry.url : nil }
    }

    func hasTimeRemaining(clock: () -> Date = Date.init) -> Bool {
        clock() < self.deadline
    }

    func compactMapWhileTimeRemains<Result>(
        _ urls: [URL],
        clock: () -> Date = Date.init,
        transform: (URL) -> Result?) -> [Result]
    {
        var results: [Result] = []
        for url in urls {
            // Enumeration already charged the entry count; enrichment shares its deadline.
            guard self.hasTimeRemaining(clock: clock) else { break }
            if let result = transform(url) {
                results.append(result)
            }
        }
        return results
    }

    private mutating func entries(
        in directory: URL,
        fileManager: FileManager,
        clock: () -> Date) -> [(url: URL, isDirectory: Bool)]
    {
        guard self.maxDepth > 0,
              self.remainingEntryCount > 0,
              clock() < self.deadline,
              let enumerator = fileManager.enumerator(
                  at: directory,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }

        var entries: [(url: URL, isDirectory: Bool)] = []
        while self.remainingEntryCount > 0, clock() < self.deadline {
            guard let url = enumerator.nextObject() as? URL else { break }
            self.remainingEntryCount -= 1
            self.didVisitEntry?()
            guard self.hasTimeRemaining(clock: clock) else { break }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            entries.append((url, isDirectory))
        }
        return entries
    }
}

enum AgentProcessPath {
    /// Foundation's tilde rules vary by runtime/SDK. An explicit directory hint avoids a metadata probe.
    static let expandsBareTilde = URL(fileURLWithPath: "~", isDirectory: false).relativePath != "~"

    static func basename(
        _ path: String,
        currentDirectory: @autoclosure () -> String = FileManager.default.currentDirectoryPath,
        expandTilde: (String) -> String = { ($0 as NSString).expandingTildeInPath },
        expandsBareTilde: Bool = Self.expandsBareTilde) -> String
    {
        let path = path.hasPrefix("~") && (expandsBareTilde || path.hasPrefix("~/")) ? expandTilde(path) : path
        let basename = (path as NSString).lastPathComponent
        if path.hasPrefix("/") { return basename }
        guard basename.isEmpty || basename == "." || basename == ".." else { return basename }
        // File URLs resolve relative dot components against CWD, but leave absolute ones alone.
        var components = currentDirectory().components(separatedBy: "/")
        for component in path.components(separatedBy: "/") {
            if component == ".." {
                if components.count > 1 { components.removeLast() }
            } else if component != "." {
                components.append(component)
            }
        }
        return components.last(where: { !$0.isEmpty }) ?? "/"
    }
}

public struct AgentProcessRecord: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let startedAt: Date?
    public let command: String
    /// Original argv when the platform exposes it. `command` remains the portable fallback.
    public let arguments: [String]?

    public init(
        pid: Int32,
        ppid: Int32,
        startedAt: Date?,
        command: String,
        arguments: [String]? = nil)
    {
        self.pid = pid
        self.ppid = ppid
        self.startedAt = startedAt
        self.command = command
        self.arguments = arguments
    }

    public var executableBasename: String {
        let firstToken = self.arguments?.first ?? self.command.split(whereSeparator: \ .isWhitespace).first
            .map(String.init) ?? ""
        let firstBasename = AgentProcessPath.basename(firstToken)
        let executable = self.arguments?.first ?? self.command
        if firstBasename != "disclaimer", executable.contains("Application Support/Claude/claude-code/claude") {
            return AgentSession.Provider.claude.rawValue
        }
        return firstBasename
    }
}

public enum AgentPSOutputParser {
    public static func parse(_ output: String) -> [AgentProcessRecord] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return output.split(whereSeparator: \ .isNewline).compactMap { rawLine -> AgentProcessRecord? in
            let fields = rawLine.split(maxSplits: 7, omittingEmptySubsequences: true, whereSeparator: \ .isWhitespace)
            guard fields.count == 8,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1])
            else { return nil }

            let dateText = fields[2...6].joined(separator: " ")
            return AgentProcessRecord(
                pid: pid,
                ppid: ppid,
                startedAt: formatter.date(from: dateText),
                command: String(fields[7]))
        }
    }

    public static func agentProcesses(from records: [AgentProcessRecord]) -> [AgentProcessRecord] {
        // Prefer argv[0] for bundle checks; prompts may contain app paths. Keep the full command fallback
        // because an unquoted executable path can contain spaces.
        let candidates = records.filter { record in
            let basename = record.executableBasename.lowercased()
            let executable = record.arguments?.first ?? record.command
            if basename == AgentSession.Provider.claude.rawValue {
                return self.isClaudeAgentExecutable(executable) && !self.isObviousClaudeHelper(record.command)
            }
            return basename == "disclaimer" && record.command.contains(AgentSession.Provider.claude.rawValue)
        }

        let recordsByPID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.pid, $0) })
        return candidates.filter { record in
            guard record.executableBasename.lowercased() == "disclaimer" else { return true }
            return !candidates.contains { child in
                child.ppid == record.pid &&
                    child.executableBasename.lowercased() == AgentSession.Provider.claude.rawValue &&
                    self.normalizedClaudeArguments(child.command) == self.normalizedClaudeArguments(record.command)
            } && recordsByPID[record.ppid] == nil
        }
    }

    public static func provider(for record: AgentProcessRecord) -> AgentSession.Provider? {
        let basename = record.executableBasename.lowercased()
        if let provider = AgentSession.Provider(rawValue: basename) {
            return provider
        }
        if basename == "disclaimer" {
            return .claude
        }
        return nil
    }

    public static func source(for record: AgentProcessRecord) -> AgentSession.Source {
        guard self.provider(for: record) == .claude else { return .cli }
        let command = record.executableBasename.lowercased() == "disclaimer"
            ? record.command : record.arguments?.first ?? record.command
        return command.contains("Application Support/Claude/claude-code") ? .desktopApp : .cli
    }

    private static func arguments(_ record: AgentProcessRecord) -> [String] {
        Array((record.arguments ?? record.command.split(whereSeparator: \ .isWhitespace).map(String.init)).dropFirst())
    }

    private static func normalizedClaudeArguments(_ command: String) -> [String] {
        let arguments = command.split(whereSeparator: \ .isWhitespace).dropFirst().map(String.init)
        return arguments.firstIndex(where: {
            AgentProcessPath.basename($0) == AgentSession.Provider.claude.rawValue
        }).map { Array(arguments.dropFirst($0 + 1)) } ?? arguments
    }

    private static func isObviousClaudeHelper(_ command: String) -> Bool {
        let lowercased = command.lowercased()
        return lowercased.contains("--version") ||
            lowercased.contains("--help") ||
            lowercased.contains("claude-code-acp")
    }

    private static func isClaudeAgentExecutable(_ command: String) -> Bool {
        let lowercased = command.lowercased()
        return !lowercased.contains(".app/") || lowercased.contains("application support/claude/claude-code/claude")
    }
}

public enum LSOFCWDOutputParser {
    public static func parse(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var currentPID: Int32?
        for line in output.split(whereSeparator: \ .isNewline).map(String.init) {
            guard let prefix = line.first else { continue }
            switch prefix {
            case "p":
                currentPID = Int32(line.dropFirst())
            case "n":
                if let currentPID {
                    result[currentPID] = String(line.dropFirst())
                }
            default:
                continue
            }
        }
        return result
    }
}

public enum ClaudeSessionProjectMapper {
    public struct Transcript: Equatable, Sendable {
        public let url: URL
        public let modifiedAt: Date

        public init(url: URL, modifiedAt: Date) {
            self.url = url
            self.modifiedAt = modifiedAt
        }
    }

    public static func escapedCWD(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar in
            let value = scalar.value
            let isASCIIAlphanumeric = (48...57).contains(value) ||
                (65...90).contains(value) ||
                (97...122).contains(value)
            return isASCIIAlphanumeric ? Character(scalar) : "-"
        })
    }

    public static func projectDirectories(
        cwd: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default) -> [URL]
    {
        let standardRoot = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        return ([standardRoot] + ClaudeDesktopProjectsLocator.roots(
            homeDirectory: homeDirectory,
            fileManager: fileManager))
            .map { $0.appendingPathComponent(self.escapedCWD(cwd), isDirectory: true) }
    }

    public static func newestTranscript(
        cwd: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default) -> (url: URL, modifiedAt: Date)?
    {
        self.transcripts(cwd: cwd, homeDirectory: homeDirectory, fileManager: fileManager).first
            .map { (url: $0.url, modifiedAt: $0.modifiedAt) }
    }

    public static func transcripts(
        cwd: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        limit: Int? = nil,
        now: Date = Date()) -> [Transcript]
    {
        var budget = DirectoryMetadataScanBudget(
            maxEntryCount: 4096,
            maxDepth: 1,
            timeLimit: 1)
        return self.transcripts(
            cwd: cwd,
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            limit: limit,
            now: now,
            budget: &budget)
    }

    static func transcripts(
        cwd: String,
        homeDirectory: URL,
        fileManager: FileManager = .default,
        limit: Int?,
        now: Date,
        budget: inout DirectoryMetadataScanBudget,
        clampModificationDate: (URL, Date, Date) -> Date = { _, modifiedAt, now in min(modifiedAt, now) })
        -> [Transcript]
    {
        let transcripts = self.projectDirectories(
            cwd: cwd,
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            budget: &budget)
            .flatMap { directory in budget.files(in: directory, fileManager: fileManager) }
            .compactMap { file -> (URL, Date)? in
                guard budget.hasTimeRemaining(),
                      file.pathExtension == "jsonl",
                      let modifiedAt = try? file.resourceValues(
                          forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (file, clampModificationDate(file, modifiedAt, now))
            }
            .sorted { $0.1 > $1.1 }
            .map { Transcript(url: $0.0, modifiedAt: $0.1) }
        guard let limit else { return transcripts }
        return Array(transcripts.prefix(max(0, limit)))
    }

    private static func projectDirectories(
        cwd: String,
        homeDirectory: URL,
        fileManager: FileManager,
        budget: inout DirectoryMetadataScanBudget) -> [URL]
    {
        let standardRoot = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        return ([standardRoot] + ClaudeDesktopProjectsLocator.roots(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            budget: &budget))
            .map { $0.appendingPathComponent(self.escapedCWD(cwd), isDirectory: true) }
    }
}

public enum AgentSessionCorrelation {
    public static func newestProcessesFirst(_ processes: [AgentProcessRecord]) -> [AgentProcessRecord] {
        processes.sorted { lhs, rhs in
            let lhsDate = lhs.startedAt ?? .distantPast
            let rhsDate = rhs.startedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.pid > rhs.pid
        }
    }

    public static func assignClaudeTranscripts(
        processes: [AgentProcessRecord],
        cwdByPID: [Int32: String],
        transcriptsByCWD: [String: [ClaudeSessionProjectMapper.Transcript]])
        -> [Int32: ClaudeSessionProjectMapper.Transcript]
    {
        var assigned: [Int32: ClaudeSessionProjectMapper.Transcript] = [:]
        var usedPaths = Set<String>()
        let unambiguousPIDs = self.unambiguousProcessIDs(processes: processes, cwdByPID: cwdByPID)
        for process in self.newestProcessesFirst(processes) {
            guard unambiguousPIDs.contains(process.pid),
                  let cwd = cwdByPID[process.pid],
                  let candidates = transcriptsByCWD[cwd]
            else { continue }
            let candidate = candidates.first { transcript in
                guard !usedPaths.contains(transcript.url.path) else { return false }
                guard let startedAt = process.startedAt else { return true }
                return transcript.modifiedAt >= startedAt
            }
            if let candidate {
                assigned[process.pid] = candidate
                usedPaths.insert(candidate.url.path)
            }
        }
        return assigned
    }

    public static func unambiguousProcessIDs(
        processes: [AgentProcessRecord],
        cwdByPID: [Int32: String]) -> Set<Int32>
    {
        let grouped = Dictionary(grouping: processes.compactMap { process -> (Int32, String)? in
            guard let cwd = cwdByPID[process.pid] else { return nil }
            return (process.pid, URL(fileURLWithPath: cwd).standardizedFileURL.path)
        }, by: { $0.1 })
        return Set(grouped.values.compactMap { records in
            records.count == 1 ? records[0].0 : nil
        })
    }
}
