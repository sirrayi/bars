import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import CodexBarCore

struct CostUsageScannerTests {
    @Test
    func `claude report preserves per-request threshold pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 9)
        let first = env.isoString(for: day)
        let second = env.isoString(for: day.addingTimeInterval(1))
        let model = "claude-sonnet-4-5"
        let firstEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": first,
            "requestId": "req_one",
            "message": [
                "id": "msg_one",
                "model": model,
                "usage": [
                    "input_tokens": 150_000,
                    "output_tokens": 0,
                ],
            ],
        ]
        let secondEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": second,
            "requestId": "req_two",
            "message": [
                "id": "msg_two",
                "model": model,
                "usage": [
                    "input_tokens": 150_000,
                    "output_tokens": 0,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/threshold.jsonl",
            contents: env.jsonl([firstEntry, secondEntry]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        let expectedRequestCost = CostUsagePricing.claudeCostUSD(
            model: model,
            inputTokens: 150_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            modelsDevCacheRoot: env.cacheRoot) ?? 0
        let aggregateCost = CostUsagePricing.claudeCostUSD(
            model: model,
            inputTokens: 300_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            modelsDevCacheRoot: env.cacheRoot) ?? 0
        let expectedCost = expectedRequestCost * 2

        #expect(report.data.count == 1)
        #expect(report.data.first?.inputTokens == 300_000)
        #expect(abs((report.data.first?.costUSD ?? 0) - expectedCost) < 0.000001)
        #expect(abs((report.data.first?.costUSD ?? 0) - aggregateCost) > 0.000001)
        #expect(abs((report.data.first?.modelBreakdowns?.first?.costUSD ?? 0) - expectedCost) < 0.000001)
    }

    @Test
    func `claude parses large lines with usage at tail`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 28)
        let iso0 = env.isoString(for: day)
        let largeText = String(repeating: "a", count: 70000)

        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "claude-sonnet-4-20250514",
                "content": [
                    ["type": "text", "text": largeText],
                ],
                "usage": [
                    "input_tokens": 3714,
                    "output_tokens": 1,
                ],
            ],
        ]
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/large-line.jsonl",
            contents: env.jsonl([assistant]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 3714)
        #expect(report.data[0].outputTokens == 1)
        #expect(report.data[0].totalTokens == 3715)
    }

    @Test
    func `claude daily report refreshes when file changes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"
        let first: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 80,
                ],
            ],
        ]
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([first]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let firstReport = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(firstReport.data.first?.totalTokens == 355)

        let second: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 40,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": 20,
                ],
            ],
        ]
        try env.jsonl([first, second]).write(to: fileURL, atomically: true, encoding: .utf8)

        let secondReport = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(secondReport.data.first?.totalTokens == 430)
    }

    @Test
    func `claude incremental parsing reads appended lines only`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"
        let normalized = CostUsagePricing.normalizeClaudeModel(model)
        let first: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 80,
                ],
            ],
        ]
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([first]))

        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let firstParse = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: range,
            providerFilter: .all,
            modelsDevCacheRoot: env.cacheRoot)
        #expect(firstParse.parsedBytes > 0)

        let second: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 40,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": 20,
                ],
            ],
        ]
        try env.jsonl([first, second]).write(to: fileURL, atomically: true, encoding: .utf8)

        let delta = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: range,
            providerFilter: .all,
            startOffset: firstParse.parsedBytes,
            modelsDevCacheRoot: env.cacheRoot)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        #expect(delta.rows.count == 1)
        let row = try #require(delta.rows.first)
        #expect(row.dayKey == dayKey)
        #expect(row.model == normalized)
        #expect(row.input == 40)
        #expect(row.cacheRead == 5)
        #expect(row.cacheCreate == 10)
        #expect(row.output == 20)
        #expect(try delta.parsedBytes == Int64(env.jsonl([first, second]).utf8.count))
    }

    @Test
    func `day key from timestamp matches ISO parsing`() {
        let timestamps = [
            "2025-12-20T23:59:59Z",
            "2025-12-20T23:59:59+02:00",
        ]

        for ts in timestamps {
            let expected = CostUsageScanner.dayKeyFromParsedISO(ts)
            let fast = CostUsageScanner.dayKeyFromTimestamp(ts)
            #expect(fast == expected)
        }
    }

    @Test
    func `claude deduplicates streaming chunks`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        let model = "claude-sonnet-4-20250514"
        let messageId = "msg_01ABC123"
        let requestId = "req_01XYZ789"

        // Streaming emits multiple chunks with same message.id + requestId.
        // Each chunk has cumulative usage, not delta.
        let chunk1: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "requestId": requestId,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 10,
                ],
            ],
        ]
        let chunk2: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "requestId": requestId,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 10,
                ],
            ],
        ]
        let chunk3: [String: Any] = [
            "type": "assistant",
            "timestamp": iso2,
            "requestId": requestId,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 10,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([chunk1, chunk2, chunk3]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        // Should only count once, not 3x.
        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 100)
        #expect(report.data[0].cacheCreationTokens == 50)
        #expect(report.data[0].cacheReadTokens == 25)
        #expect(report.data[0].outputTokens == 10)
        #expect(report.data[0].totalTokens == 185)
    }

    @Test
    func `claude counts entries without ids as separate`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"

        // Entries without message.id or requestId should still be counted
        // (fallback for older log formats).
        let entry1: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 50,
                ],
            ],
        ]
        let entry2: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 100,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([entry1, entry2]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        // Both entries should be counted since no IDs to dedupe.
        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 300)
        #expect(report.data[0].outputTokens == 150)
        #expect(report.data[0].totalTokens == 450)
    }

    @Test
    func `claude counts different request ids separately`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"
        let messageId = "msg_01ABC123"

        let entry1: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "requestId": "req_01AAA",
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 10,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 5,
                ],
            ],
        ]
        let entry2: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "requestId": "req_01BBB",
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 20,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 10,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([entry1, entry2]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 30)
        #expect(report.data[0].outputTokens == 15)
        #expect(report.data[0].totalTokens == 45)
    }
}

struct CostUsageTestEnvironment {
    let root: URL
    let cacheRoot: URL
    let codexHomeRoot: URL
    let codexSessionsRoot: URL
    let codexArchivedSessionsRoot: URL
    let claudeProjectsRoot: URL
    let piSessionsRoot: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-cost-usage-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        self.codexHomeRoot = root.appendingPathComponent("codex-home", isDirectory: true)
        self.codexSessionsRoot = self.codexHomeRoot.appendingPathComponent("sessions", isDirectory: true)
        self.codexArchivedSessionsRoot = self.codexHomeRoot
            .appendingPathComponent("archived_sessions", isDirectory: true)
        self.claudeProjectsRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        self.piSessionsRoot = root.appendingPathComponent("pi-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: self.cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.codexSessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.codexArchivedSessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.claudeProjectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.piSessionsRoot, withIntermediateDirectories: true)
    }

    func makeLocalNoon(year: Int, month: Int, day: Int) throws -> Date {
        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        comps.minute = 0
        comps.second = 0
        guard let date = comps.date else { throw NSError(domain: "CostUsageTestEnvironment", code: 1) }
        return date
    }

    func isoString(for date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    func writeCodexSessionFile(day: Date, filename: String, contents: String) throws -> URL {
        let url = try self.codexSessionFileURL(day: day, filename: filename)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func seedCodexSessionFile(day: Date, filename: String, contents: String) throws -> URL {
        let url = try self.codexSessionFileURL(day: day, filename: filename)
        // Initial corpus files have no readers until setup returns; no atomic publication or fsync is needed.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(contents.utf8))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        return url
    }

    private func codexSessionFileURL(day: Date, filename: String) throws -> URL {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let y = String(format: "%04d", comps.year ?? 1970)
        let m = String(format: "%02d", comps.month ?? 1)
        let d = String(format: "%02d", comps.day ?? 1)

        let dir = self.codexSessionsRoot
            .appendingPathComponent(y, isDirectory: true)
            .appendingPathComponent(m, isDirectory: true)
            .appendingPathComponent(d, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        return dir.appendingPathComponent(filename, isDirectory: false)
    }

    func writeClaudeProjectFile(relativePath: String, contents: String) throws -> URL {
        let url = self.claudeProjectsRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeClaudeDesktopLocalAgentFile(relativePath: String, contents: String) throws -> URL {
        let localAgentRoot = self.root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
            .appendingPathComponent("workspace-id", isDirectory: true)
            .appendingPathComponent("session-id", isDirectory: true)
            .appendingPathComponent("local_agent", isDirectory: true)
        let url = localAgentRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeClaudeDesktopLocalAgentProjectFile(relativePath: String, contents: String) throws -> URL {
        try self.writeClaudeDesktopLocalAgentFile(
            relativePath: ".claude/projects/\(relativePath)",
            contents: contents)
    }

    func writeClaudeDesktopCodeSessionProjectFile(relativePath: String, contents: String) throws -> URL {
        let projectsRoot = self.root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
            .appendingPathComponent("account-id", isDirectory: true)
            .appendingPathComponent("org-id", isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let url = projectsRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeClaudeDesktopSharedProjectFile(relativePath: String, contents: String) throws -> URL {
        let projectsRoot = self.root
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let url = projectsRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeNestedClaudeDesktopLocalAgentProjectFile(relativePath: String, contents: String) throws -> URL {
        let projectsRoot = self.root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
            .appendingPathComponent("workspace-id", isDirectory: true)
            .appendingPathComponent("session-id", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("local_agent", isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let url = projectsRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeCodexArchivedSessionFile(filename: String, contents: String) throws -> URL {
        let url = self.codexArchivedSessionsRoot.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writePiSessionFile(relativePath: String, contents: String) throws -> URL {
        let url = self.piSessionsRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func jsonl(_ objects: [Any]) throws -> String {
        let lines = try objects.map { obj in
            let data = try JSONSerialization.data(withJSONObject: obj)
            guard let text = String(bytes: data, encoding: .utf8) else {
                throw NSError(domain: "CostUsageTestEnvironment", code: 2)
            }
            return text
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func cleanup() {
        for provider in [UsageProvider.claude] {
            for context in [CostUsageReportContext.regular, .spendDashboard] {
                CostUsageScanner.evictClaudeReportMemoForTesting(
                    provider: provider, cacheRoot: self.cacheRoot, reportContext: context)
                CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: CostUsageClaudeCacheIO.cacheFileURL(
                    provider: provider, cacheRoot: self.cacheRoot, reportContext: context))
            }
        }
        try? FileManager.default.removeItem(at: self.root)
    }
}
