import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIConfigCommandTests {
    @Test
    func `config set api key parses provider stdin and no enable flags`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configSetAPIKeySignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--provider", "elevenlabs",
            "--stdin",
            "--no-enable",
            "--json",
        ])

        #expect(parsed.options["provider"] == ["elevenlabs"])
        #expect(parsed.flags.contains("stdin"))
        #expect(parsed.flags.contains("noEnable"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func `config set api key for an unsupported provider explains the limitation`() {
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .devin) == false)
        let devinMsg = CodexBarCLI.unsupportedAPIKeyErrorMessage(rawProvider: "devin")
        #expect(devinMsg == "devin does not support config API keys.")
    }

    @Test
    func `config provider toggle parses provider and json flags`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configProviderToggleSignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--provider", "grok",
            "--json",
            "--pretty",
        ])

        #expect(parsed.options["provider"] == ["grok"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
        #expect(parsed.flags.contains("pretty"))
    }

    @Test
    func `config set api key rejects ambiguous input`() {
        #expect(throws: CLIArgumentError.self) {
            try CodexBarCLI.resolveConfigAPIKeyInput(apiKey: "xi-test-token", readFromStdin: true)
        }
    }

    @Test
    func `config help documents set api key`() {
        let help = CodexBarCLI.configHelp(version: "0.0.0")

        #expect(help.contains("config set-api-key --provider <name>"))
        #expect(help.contains("config providers"))
        #expect(help.contains("config enable --provider <name>"))
        #expect(help.contains("config disable --provider <name>"))
        #expect(help.contains("--stdin"))
        #expect(help.contains("--usage-scope team"))
        #expect(help.contains("enables that provider by default"))
        #expect(help.contains("--show-secrets"))
    }

    @Test
    func `config dump parses show-secrets flag`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configDumpSignatureForTesting())
        let parsed = try parser.parse(arguments: ["--show-secrets", "--pretty"])

        #expect(parsed.flags.contains("showSecrets"))
        #expect(parsed.flags.contains("pretty"))
    }

    private static func runConfigDump(configURL: URL, showSecrets: Bool) async throws -> Data {
        let environment = ProcessInfo.processInfo.environment.merging([
            CodexBarConfigStore.pathEnvironmentKey: configURL.path,
            "HOME": configURL.deletingLastPathComponent().path,
            "CFFIXED_USER_HOME": configURL.deletingLastPathComponent().path,
            "CODEX_HOME": configURL.deletingLastPathComponent().appendingPathComponent(".opencode").path,
            // Spawned CLI binaries match no test-process name pattern; make the
            // keychain suppression explicit instead of relying on env inheritance.
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        ]) { _, fixturePath in fixturePath }

        // Drain both pipes while the child runs; waiting first can block its final stdout flush.
        let result = try await SubprocessRunner.run(
            binary: TestBuildProducts.executableURL(named: "CodexBarCLI").path,
            arguments: ["config", "dump"] + (showSecrets ? ["--show-secrets"] : []),
            environment: environment,
            timeout: 15,
            maxOutputBytes: 1024 * 1024,
            label: "fixture config dump")
        return Data(result.stdout.utf8)
    }
}
