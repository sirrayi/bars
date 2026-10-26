import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIDiagnoseCommandTests {
    @Test
    func `diagnose help describes generic JSON export`() {
        let help = CodexBarCLI.diagnoseHelp(version: "0.0.0")

        #expect(help.contains("codexbar diagnose --provider <name|all> --format json"))
        #expect(help.contains("codexbar diagnose --provider all --format json"))
        #expect(help.contains("--redact"))
        #expect(help.contains("--output <path>"))
        #expect(help.contains("safe JSON export"))
        #expect(help.contains("raw API tokens"))
    }

    @Test
    func `diagnose output writer creates parent directories`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarDiagnoseTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let output = root.appendingPathComponent("nested/diagnostic.json")
        try CodexBarCLI.writeDiagnosticExport(#"{"provider":"minimax"}"#, to: output.path)

        let contents = try String(contentsOf: output, encoding: .utf8)
        #expect(contents == #"{"provider":"minimax"}"#)
    }

    @Test
    func `generic diagnose auth summary does not assume ambient credentials`() {
        let summary = CodexBarCLI._diagnosticAuthSummaryForTesting(
            provider: .codex,
            account: nil,
            config: nil,
            environment: [:],
            settings: nil)

        #expect(!summary.configured)
        #expect(summary.modes.isEmpty)
    }
}
