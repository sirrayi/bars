import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIConfigSourceCommandTests {
    @Test
    func `set source follows descriptors for every provider alias and mode`() throws {
        for (alias, provider) in ProviderDescriptorRegistry.cliNameMap {
            let supported = ProviderDescriptorRegistry.descriptor(for: provider).fetchPlan.sourceModes
            for mode in ProviderSourceMode.allCases {
                if supported.contains(mode) {
                    let selection = try CodexBarCLI.configSourceSelection(provider: alias, source: mode.rawValue)
                    #expect(selection.provider == provider)
                    #expect(selection.source == mode)
                } else {
                    #expect(throws: CLIArgumentError.self) {
                        _ = try CodexBarCLI.configSourceSelection(provider: alias, source: mode.rawValue)
                    }
                }
            }
        }
    }

    @Test
    func `set source preserves config fields and auto removes the override`() throws {
        let raw = #"{"version":1,"providers":["# +
            #"{"id":"claude","enabled":false,"source":"web","cookieHeader":"fixture-cookie","# +
            #""futureField":{"keep":true}},"# +
            #"{"id":"future-provider","enabled":true,"opaque":"keep"}]}"#
        let config = try CodexBarConfig.decode(from: Data(raw.utf8))
        let updated = CodexBarCLI.configSettingSource(config, provider: .claude, source: .cli)
        let entry = try #require(updated.providerConfig(for: .claude))
        #expect(entry.source == .cli)
        #expect(entry.enabled == false)
        #expect(entry.cookieHeader == "fixture-cookie")
        let data = try updated.encodedData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(object["providers"] as? [[String: Any]])
        #expect(providers.first { $0["id"] as? String == "claude" }?["futureField"] as? [String: Bool]
            == ["keep": true])
        #expect(providers.first { $0["id"] as? String == "future-provider" }?["opaque"] as? String == "keep")
        let reset = CodexBarCLI.configSettingSource(updated, provider: .claude, source: .auto)
        #expect(reset.providerConfig(for: .claude)?.source == nil)
        #expect(reset.providerConfig(for: .claude)?.enabled == false)
    }

    @Test
    func `set source accepts shared JSON output options`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(ConfigSetSourceOptions()).flattened())
        let values = try parser.parse(arguments: ["--provider", "claude", "--source", "cli", "--json", "--pretty"])
        #expect(values.options["provider"] == ["claude"])
        #expect(values.options["source"] == ["cli"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: values) == .json)
        #expect(values.flags.contains("pretty"))
        #expect(CodexBarCLI.configHelp(version: "fixture").contains("config set-source"))
    }

    @Test(arguments: ["missing", "malformed", "valid"])
    func `invalid source arguments never load or write config`(fixture: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-source-invalid-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        // Invalid JSON makes a premature config read observable as the wrong error.
        let before = Data((fixture == "valid"
                ? #"{ "version":1, "providers":[{"id":"claude","enabled":false,"cookieHeader":"fixture-cookie"}] }"#
                : "invalid config fixture\n").utf8)
        if fixture != "missing" { try before.write(to: url) }
        for (arguments, message) in [
            (["--source", "auto"], "Unknown or missing provider"),
            (["--provider", "unknown", "--source", "auto"], "Unknown or missing provider"),
            (["--provider", "claude"], "Unknown or missing source"),
            (["--provider", "claude", "--source", "unknown"], "Unknown or missing source"),
            (["--provider", "commandcode", "--source", "cli"], "Source cli is not supported for commandcode"),
        ] {
            do {
                _ = try await Self.run(root: root, arguments: arguments)
                Issue.record("Invalid arguments unexpectedly succeeded")
            } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
                #expect(code == 1)
                #expect(stderr.contains(message))
            }
            if fixture != "missing" {
                #expect(try Data(contentsOf: url) == before)
            } else {
                #expect(!FileManager.default.fileExists(atPath: url.path))
            }
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("lock").path))
        }
    }

    private static func run(root: URL, arguments: [String]) async throws -> String {
        let environment = [
            "CODEXBAR_CONFIG": root.appendingPathComponent("config.json").path,
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex").path,
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        ]
        let result = try await SubprocessRunner.run(
            binary: TestBuildProducts.executableURL(named: "CodexBarCLI").path,
            arguments: ["config", "set-source"] + arguments,
            environment: environment,
            timeout: 15,
            label: "synthetic config set source")
        return result.stdout
    }
}
