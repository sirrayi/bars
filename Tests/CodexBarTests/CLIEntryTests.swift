import CodexBarCore
import Commander
import Foundation
import XCTest
@testable import CodexBarCLI

final class CLIEntryTests: XCTestCase {
    func test_effectiveArgvDefaultsToUsage() {
        XCTAssertEqual(CodexBarCLI.effectiveArgv([]), ["usage"])
        XCTAssertEqual(CodexBarCLI.effectiveArgv(["--json"]), ["usage", "--json"])
        XCTAssertEqual(CodexBarCLI.effectiveArgv(["usage", "--json"]), ["usage", "--json"])
    }

    func test_rootHelpAdvertisesDashboardSnapshotCommand() {
        let help = CodexBarCLI.rootHelp(version: "0.0.0")

        XCTAssertTrue(help.contains("codexbar dashboard [--pretty] [--timeout <seconds>] [--output <path>]"))
    }

    func test_dashboardCommandIsRegisteredAndParsesOptions() throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        let invocation = try program.resolve(
            argv: ["dashboard", "--pretty", "--timeout", "45", "--output", "/tmp/snapshot.json"])

        XCTAssertEqual(invocation.path, ["dashboard"])
        XCTAssertTrue(invocation.parsedValues.flags.contains("pretty"))
        XCTAssertEqual(invocation.parsedValues.options["timeout"], ["45"])
        XCTAssertEqual(invocation.parsedValues.options["output"], ["/tmp/snapshot.json"])
    }

    func test_dashboardTimeoutIsBoundedAndCanBeDisabled() {
        XCTAssertEqual(
            CodexBarCLI.decodeDashboardTimeout(from: ParsedValues(positional: [], options: [:], flags: [])),
            30)
        XCTAssertEqual(
            CodexBarCLI.decodeDashboardTimeout(
                from: ParsedValues(positional: [], options: ["timeout": ["0"]], flags: [])),
            0)
        XCTAssertEqual(
            CodexBarCLI.decodeDashboardTimeout(
                from: ParsedValues(positional: [], options: ["timeout": ["86400"]], flags: [])),
            86400)

        for value in ["-1", "nan", "inf", "86401"] {
            XCTAssertNil(CodexBarCLI.decodeDashboardTimeout(
                from: ParsedValues(positional: [], options: ["timeout": [value]], flags: [])))
        }
    }

    func test_dashboardCommanderErrorsStayOffStdout() throws {
        let result = try Self.runCLI(arguments: ["dashboard", "--json"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertFalse(result.stderr.isEmpty)
    }

    /// `Program.resolve` throws before `ParsedValues` (and `resolveUsageOutputPreferences`) exist, so
    /// a genuine parse failure -- an unrecognized option here -- has to go through the argv-level
    /// `CLIOutputPreferences.from(argv:)` bootstrap scanner. Regression test for that scanner not
    /// recognizing `--format toon` and silently falling back to plain stderr text.
    func test_usageCommanderParseFailureWithToonAndJSONRendersTOON() throws {
        let result = try Self.runCLI(arguments: ["usage", "--format", "toon", "--json", "--bogus-flag-xyz"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.isEmpty)
        let stdout = try XCTUnwrap(String(bytes: result.stdout, encoding: .utf8))
        XCTAssertTrue(stdout.contains("- provider: cli"))
        XCTAssertTrue(stdout.contains("Unknown option --bogus-flag-xyz"))
        XCTAssertFalse(stdout.hasPrefix("[{"), "TOON error output should not fall back to a JSON array literal")
    }

    func test_usageCommanderParseFailureRendersTOONWhenRequested() throws {
        let result = try Self.runCLI(arguments: ["usage", "--bogus-flag-xyz", "--format", "toon"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.isEmpty)
        let stdout = try XCTUnwrap(String(bytes: result.stdout, encoding: .utf8))
        XCTAssertTrue(stdout.contains("- provider: cli"))
        XCTAssertTrue(stdout.contains("message: Unknown option --bogus-flag-xyz"))
        XCTAssertFalse(stdout.hasPrefix("[{"), "TOON error output should not fall back to a JSON array literal")
        XCTAssertFalse(stdout.contains("\"provider\""), "TOON error output should not contain JSON-quoted keys")
    }

    func test_usageCommanderParseFailureWithEqualsFormatRendersTOON() throws {
        let result = try Self.runCLI(arguments: ["usage", "--bogus-flag-xyz", "--format=toon"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.isEmpty)
        let stdout = try XCTUnwrap(String(bytes: result.stdout, encoding: .utf8))
        XCTAssertTrue(stdout.contains("Unknown option --bogus-flag-xyz"))
    }

    /// TOON is a `usage`-only contract. Commands whose help promises `text | json` must keep treating
    /// `--format toon` as an unrecognized value -- reporting on stderr as text -- rather than silently
    /// switching to the JSON branch.
    func test_nonUsageCommandsDoNotInheritTOONOutput() throws {
        for command in ["cost", "diagnose", "cache"] {
            let result = try Self.runCLI(arguments: [command, "--format", "toon", "--bogus-flag-xyz"])

            XCTAssertNotEqual(result.status, 0, "\(command) should still fail on an unknown option")
            XCTAssertTrue(result.stdout.isEmpty, "\(command) must not emit a structured payload on stdout")
            let stderr = try XCTUnwrap(String(bytes: result.stderr, encoding: .utf8))
            XCTAssertTrue(
                stderr.contains("Unknown option --bogus-flag-xyz"),
                "\(command) should report the parse failure as text on stderr")
        }
    }

    func test_dashboardCommandPrintsOneSnapshotAndExits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-dashboard-command-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = CodexBarConfig.makeDefault()
        config.providers = config.providers.map { provider in
            var disabled = provider
            disabled.enabled = false
            return disabled
        }
        let configURL = root.appendingPathComponent("config.json")
        try CodexBarConfigStore(fileURL: configURL).save(config)

        let result = try Self.runCLI(
            arguments: ["dashboard"],
            environment: [CodexBarConfigStore.pathEnvironmentKey: configURL.path])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.last, 0x0A)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        XCTAssertTrue(providers.isEmpty)
        let host = try XCTUnwrap(object["host"] as? [String: Any])
        XCTAssertEqual(host["refreshIntervalSeconds"] as? Int, 0)
    }

    func test_dashboardOutputWritesSnapshotFileAndKeepsStdoutSilent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-dashboard-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = CodexBarConfig.makeDefault()
        config.providers = config.providers.map { provider in
            var disabled = provider
            disabled.enabled = false
            return disabled
        }
        let configURL = root.appendingPathComponent("config.json")
        try CodexBarConfigStore(fileURL: configURL).save(config)

        let snapshotURL = root.appendingPathComponent("snapshot.json")
        // Pre-existing content must be atomically replaced, not appended to.
        try Data("stale".utf8).write(to: snapshotURL)

        let result = try Self.runCLI(
            arguments: ["dashboard", "--output", snapshotURL.path],
            environment: [CodexBarConfigStore.pathEnvironmentKey: configURL.path])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.isEmpty)

        let written = try Data(contentsOf: snapshotURL)
        XCTAssertEqual(written.last, 0x0A)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)

        let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o644)

        // The staged temp file must not survive a successful publish.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("codexbar-dashboard-") }
        XCTAssertEqual(leftovers, [])
    }

    func test_dashboardOutputRejectsEmptyPathAsArgsError() throws {
        let result = try Self.runCLI(arguments: ["dashboard", "--output", ""])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stdout.isEmpty)
        let stderrText = try XCTUnwrap(String(bytes: result.stderr, encoding: .utf8))
        XCTAssertTrue(stderrText.contains("--output requires a non-empty file path."))
    }

    func test_dashboardAtomicWriteFailsWhenDirectoryIsMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("snapshot.json")

        XCTAssertThrowsError(
            try CodexBarCLI.writeDashboardSnapshotAtomically(Data("{}".utf8), toPath: missing.path))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("does not exist"))
        }
    }

    func test_dashboardAtomicWriteReplacesExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-atomic-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("snapshot.json")
        try Data("old".utf8).write(to: target)

        try CodexBarCLI.writeDashboardSnapshotAtomically(Data("new".utf8), toPath: target.path)

        XCTAssertEqual(try Data(contentsOf: target), Data("new".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o644)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["snapshot.json"])
    }

    func test_decodesFormatFromOptionsAndFlags() {
        let jsonOption = ParsedValues(positional: [], options: ["format": ["json"]], flags: [])
        XCTAssertEqual(CodexBarCLI._decodeFormatForTesting(from: jsonOption), .json)

        let jsonFlag = ParsedValues(positional: [], options: [:], flags: ["json"])
        XCTAssertEqual(CodexBarCLI._decodeFormatForTesting(from: jsonFlag), .json)

        let textDefault = ParsedValues(positional: [], options: [:], flags: [])
        XCTAssertEqual(CodexBarCLI._decodeFormatForTesting(from: textDefault), .text)
    }

    func test_providerSelectionPrefersOverride() {
        let selection = CodexBarCLI.providerSelection(rawOverride: "devin", enabled: [.claude, .opencode])
        XCTAssertEqual(selection.asList, [.devin])
    }

    func test_normalizeVersionExtractsNumeric() {
        XCTAssertEqual(CodexBarCLI.normalizeVersion(raw: "codex 1.2.3 (build 4)"), "1.2.3")
        XCTAssertEqual(CodexBarCLI.normalizeVersion(raw: "  v2.0  "), "2.0")
    }

    func test_makeHeaderIncludesVersionWhenAvailable() {
        let header = CodexBarCLI.makeHeader(provider: .devin, version: "1.2.3", source: "cli")
        XCTAssertTrue(header.contains("Devin"))
        XCTAssertTrue(header.contains("1.2.3"))
        XCTAssertTrue(header.contains("cli"))
    }

    func test_cliVersionFallsBackToContainingAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("CodexBar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)

        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = ["CFBundleShortVersionString": "9.8.7"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoURL)

        let helperURL = helpersURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)

        XCTAssertEqual(CodexBarCLI.containingAppVersion(for: helperURL), "9.8.7")
    }

    func test_containingAppVersionTerminatesOutsideAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-noapp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let executableURL = binURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: executableURL)

        XCTAssertNil(CodexBarCLI.containingAppVersion(for: executableURL))
        XCTAssertNil(CodexBarCLI.containingAppVersion(for: URL(fileURLWithPath: "/")))
    }

    func test_nextAncestorRejectsNonDecreasingParents() {
        let current = URL(fileURLWithPath: "/synthetic/current")
        let candidates = [
            URL(fileURLWithPath: "/distinct/sibling"),
            URL(fileURLWithPath: "/synthetic/current/child"),
        ]

        for candidate in candidates {
            var calls = 0
            let ancestor = CodexBarCLI.nextAncestor(from: current) { _ in
                calls += 1
                return candidate
            }

            XCTAssertNil(ancestor)
            XCTAssertEqual(calls, 1)
        }
    }

    func test_cliVersionFollowsSymlinkedHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("CodexBar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = ["CFBundleShortVersionString": "2.4.6"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoURL)

        let helperURL = helpersURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)

        let symlinkURL = binURL.appendingPathComponent("codexbar")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: helperURL)

        XCTAssertEqual(CodexBarCLI.currentVersion(bundleVersion: nil, executablePath: symlinkURL.path), "2.4.6")
    }

    func test_cliVersionFallsBackToAdjacentVersionFile() throws {
        try self.expectAdjacentVersionFile(raw: "v3.2.1\n", expected: "3.2.1")
        try self.expectAdjacentVersionFile(raw: "3.2.2\n", expected: "3.2.2")
        try self.expectAdjacentVersionFile(raw: "version-3.2.3\n", expected: "version-3.2.3")
    }

    func test_cliVersionFindsAdjacentVersionWhenInvokedViaRelativePathAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-invocation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installURL = root.appendingPathComponent("install/bin", isDirectory: true)
        let linksURL = root.appendingPathComponent("links", isDirectory: true)
        let workingDirectoryURL = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: installURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linksURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)

        let executableURL = installURL.appendingPathComponent("CodexBarCLI")
        try FileManager.default.copyItem(
            at: TestBuildProducts.executableURL(named: "CodexBarCLI"), to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try "8.7.6\n".write(
            to: installURL.appendingPathComponent("VERSION"),
            atomically: false,
            encoding: .utf8)

        XCTAssertEqual(
            try Self.runVersionCommand(
                executableURL: executableURL,
                argv0: "install/bin/CodexBarCLI",
                currentDirectoryURL: workingDirectoryURL),
            "CodexBar 8.7.6\n")

        let symlinkURL = linksURL.appendingPathComponent("codexbar")
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: "../install/bin/CodexBarCLI")
        XCTAssertEqual(
            try Self.runVersionCommand(
                executableURL: symlinkURL,
                argv0: "codexbar",
                currentDirectoryURL: workingDirectoryURL),
            "CodexBar 8.7.6\n")
    }

    func test_cliVersionPrefersAdjacentVersionOverStandaloneBundleName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let helperURL = binURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)
        try "4.5.6\n".write(
            to: binURL.appendingPathComponent("VERSION"),
            atomically: false,
            encoding: .utf8)

        XCTAssertEqual(
            CodexBarCLI.currentVersion(bundleVersion: "CodexBar", executablePath: helperURL.path),
            "4.5.6")
    }

    private func expectAdjacentVersionFile(raw: String, expected: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let helperURL = binURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)
        try raw.write(
            to: binURL.appendingPathComponent("VERSION"),
            atomically: false,
            encoding: .utf8)

        XCTAssertEqual(CodexBarCLI.currentVersion(bundleVersion: nil, executablePath: helperURL.path), expected)
    }

    private static func runVersionCommand(
        executableURL: URL,
        argv0: String,
        currentDirectoryURL: URL) throws -> String
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            "exec -a \"$1\" \"$2\" --version",
            "codexbar-version-test",
            argv0,
            executableURL.path,
        ]
        process.currentDirectoryURL = currentDirectoryURL
        // Spawned CLI binaries match no test-process name pattern; make the
        // keychain suppression explicit instead of relying on env inheritance.
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1"]) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(bytes: errorOutput, encoding: .utf8)
                ?? "CodexBarCLI exited without an error message"
            throw NSError(domain: "CLIEntryTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        guard let text = String(bytes: output, encoding: .utf8) else {
            throw NSError(domain: "CLIEntryTests", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "CodexBarCLI produced non-UTF-8 output",
            ])
        }
        return text
    }

    func test_mapsErrorsToExitCodes() {
        XCTAssertEqual(CodexBarCLI.mapError(ClaudeUsageError.claudeNotInstalled), ExitCode(2))
        XCTAssertEqual(CodexBarCLI.mapError(TTYCommandRunner.Error.timedOut), ExitCode(4))
        XCTAssertEqual(CodexBarCLI.mapError(ClaudeWebFetchStrategyError.timedOut(seconds: 1)), ExitCode(4))
        XCTAssertEqual(CodexBarCLI.mapError(ClaudeUsageError.parseFailed("synthetic")), ExitCode(3))
    }

    func test_providerSelectionFallsBackToCustomWhenNonPrimary() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [.devin, .opencode])
        switch selection {
        case let .custom(providers):
            XCTAssertEqual(providers, [.devin, .opencode])
        default:
            XCTFail("Expected custom selection")
        }
    }

    func test_providerSelectionHonorsEmptyEnabledSet() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [])
        switch selection {
        case let .custom(providers):
            XCTAssertEqual(providers, [])
        default:
            XCTFail("Expected empty custom selection")
        }
    }

    func test_decodesSourceAndTimeoutOptions() throws {
        let signature = CodexBarCLI._usageSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--web-timeout", "45", "--source", "oauth"])
        XCTAssertEqual(try CodexBarCLI._decodeWebTimeoutForTesting(from: parsed), 45)
        XCTAssertEqual(CodexBarCLI._decodeSourceModeForTesting(from: parsed), .oauth)

        let parsedWeb = try parser.parse(arguments: ["--web"])
        XCTAssertEqual(CodexBarCLI._decodeSourceModeForTesting(from: parsedWeb), .web)
    }

    func test_rejectsUnsafeWebTimeoutOptions() throws {
        for value in ["-1", "nan", "inf", "1e300"] {
            let parsed = ParsedValues(positional: [], options: ["webTimeout": [value]], flags: [])
            XCTAssertThrowsError(try CodexBarCLI._decodeWebTimeoutForTesting(from: parsed))
        }
    }

    func test_shouldUseColorRespectsFormatAndFlags() {
        XCTAssertFalse(CodexBarCLI.shouldUseColor(noColor: true, format: .text))
        XCTAssertFalse(CodexBarCLI.shouldUseColor(noColor: false, format: .json))
    }
}

extension CLIEntryTests {
    fileprivate static func runCLI(
        arguments: [String],
        environment: [String: String] = [:]) throws -> (status: Int32, stdout: Data, stderr: Data)

    {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = TestBuildProducts.executableURL(named: "CodexBarCLI")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "CODEX_HOME": home.appendingPathComponent(".devin").path,
            "CODEXBAR_CONFIG": home.appendingPathComponent("config.json").path,
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        ]) { _, override in override }.merging(environment) { _, override in override }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr.fileHandleForReading.readDataToEndOfFile())
    }
}
