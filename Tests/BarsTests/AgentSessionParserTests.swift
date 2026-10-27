import Foundation
import Testing
@testable import BarsCore

struct AgentSessionParserTests {
    @Test
    func `ps parser deduplicates desktop wrapper and excludes non Claude agents and helpers`() throws {
        let output = try Self.fixtureString("agent-sessions-ps", extension: "txt")
        let records = AgentPSOutputParser.parse(output)
        let agents = AgentPSOutputParser.agentProcesses(from: records)

        #expect(records.count == 18)
        #expect(agents.map(\ .pid) == [102])
        #expect(AgentPSOutputParser.provider(for: agents[0]) == .claude)
        #expect(AgentPSOutputParser.source(for: agents[0]) == .desktopApp)
        let unrelatedBun = try #require(records.first { $0.pid == 507 })
        let unrelatedNpm = try #require(records.first { $0.pid == 508 })
        #expect(AgentPSOutputParser.provider(for: unrelatedBun) == nil)
        #expect(AgentPSOutputParser.provider(for: unrelatedNpm) == nil)
        for helperPID in [503, 504, 505, 506] {
            let helper = try #require(records.first { $0.pid == helperPID })
            #expect(AgentPSOutputParser.provider(for: helper) == nil)
            #expect(AgentPSOutputParser.source(for: helper) == .cli)
        }
    }

    @Test
    func `lsof parser maps batched cwd records`() throws {
        let output = try Self.fixtureString("agent-sessions-lsof", extension: "txt")
        let paths = LSOFCWDOutputParser.parse(output)

        #expect(paths[102] == "/Users/test/Projects/alpha")
        #expect(paths[201] == "/Users/test/Projects/project with spaces")
    }

    @Test
    func `same cwd processes remain uncorrelated when ownership is ambiguous`() {
        let olderStart = Date(timeIntervalSince1970: 100)
        let newerStart = Date(timeIntervalSince1970: 200)
        let older = AgentProcessRecord(pid: 10, ppid: 1, startedAt: olderStart, command: "claude")
        let newer = AgentProcessRecord(pid: 20, ppid: 1, startedAt: newerStart, command: "claude")
        let olderTranscript = ClaudeSessionProjectMapper.Transcript(
            url: URL(fileURLWithPath: "/tmp/older.jsonl"),
            modifiedAt: Date(timeIntervalSince1970: 150))
        let newerTranscript = ClaudeSessionProjectMapper.Transcript(
            url: URL(fileURLWithPath: "/tmp/newer.jsonl"),
            modifiedAt: Date(timeIntervalSince1970: 250))

        let assignments = AgentSessionCorrelation.assignClaudeTranscripts(
            processes: [older, newer],
            cwdByPID: [10: "/project", 20: "/project"],
            transcriptsByCWD: ["/project": [newerTranscript, olderTranscript]])

        #expect(assignments.isEmpty)
    }

    static func fixtureURL(_ name: String, extension fileExtension: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"))
    }

    static func fixtureString(_ name: String, extension fileExtension: String) throws -> String {
        try String(contentsOf: self.fixtureURL(name, extension: fileExtension), encoding: .utf8)
    }
}
