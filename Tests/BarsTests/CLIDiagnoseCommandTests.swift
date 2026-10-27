import BarsCore
import Foundation
import Testing
@testable import BarsCLI

struct CLIDiagnoseCommandTests {
    @Test
    func `diagnose help describes generic JSON export`() {
        let help = BarsCLI.diagnoseHelp(version: "0.0.0")

        #expect(help.contains("bars diagnose --provider <name|all> --format json"))
        #expect(help.contains("bars diagnose --provider all --format json"))
        #expect(help.contains("--redact"))
        #expect(help.contains("--output <path>"))
        #expect(help.contains("safe JSON export"))
        #expect(help.contains("raw API tokens"))
    }

    @Test
    func `diagnose output writer creates parent directories`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarsDiagnoseTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let output = root.appendingPathComponent("nested/diagnostic.json")
        try BarsCLI.writeDiagnosticExport(#"{"provider":"minimax"}"#, to: output.path)

        let contents = try String(contentsOf: output, encoding: .utf8)
        #expect(contents == #"{"provider":"minimax"}"#)
    }

    @Test
    func `generic diagnose auth summary does not assume ambient credentials`() {
        let summary = BarsCLI._diagnosticAuthSummaryForTesting(
            provider: .claude,
            account: nil,
            config: nil,
            environment: [:],
            settings: nil)

        #expect(!summary.configured)
        #expect(summary.modes.isEmpty)
    }
}
