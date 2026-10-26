import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIProviderSelectionTests {
    @Test
    func `help mentions source flag`() {
        let usage = CodexBarCLI.usageHelp(version: "0.0.0")
        let root = CodexBarCLI.rootHelp(version: "0.0.0")

        func tokens(_ text: String) -> [String] {
            let split = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]|,"))
            return text.components(separatedBy: split).filter { !$0.isEmpty }
        }

        #expect(usage.contains("--source"))
        #expect(root.contains("--source"))
        #expect(usage.contains("--web-timeout"))
        #expect(usage.contains("--web-debug-dump-html"))
        #expect(!tokens(usage).contains("--web"))
        #expect(!tokens(root).contains("--web"))
        #expect(!tokens(usage).contains("--claude-source"))
        #expect(!tokens(root).contains("--claude-source"))
    }

    @Test
    func `help advertises the toon output format`() {
        let usage = CodexBarCLI.usageHelp(version: "0.0.0")
        let root = CodexBarCLI.rootHelp(version: "0.0.0")

        #expect(usage.contains("--format text|json|toon"))
        #expect(root.contains("--format text|json|toon"))
        #expect(usage.contains("codexbar usage --format toon"))
        #expect(root.contains("codexbar --format toon"))
    }

    @Test
    func `provider selection uses both for codex and claude`() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [.opencode, .claude])
        #expect(selection.asList == [.opencode, .claude])
    }

    @Test
    func `provider selection honors empty enabled set`() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [])
        #expect(selection.asList == [])
    }
}
