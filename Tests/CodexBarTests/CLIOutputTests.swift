import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIOutputTests {
    @Test
    func `output preferences json only forces JSON`() {
        let output = CLIOutputPreferences.from(argv: ["--json-only"])
        #expect(output.jsonOnly == true)
        #expect(output.format == .json)
    }

    @Test
    func `argv bootstrap preferences recognize toon before Commander parsing`() {
        // This is the scanner CLIEntry uses to render a Program.resolve parse failure (an unknown
        // option, before ParsedValues exists), so it has to recognize --format toon independently
        // of the post-parse resolveUsageOutputPreferences path.
        let spaceForm = CLIOutputPreferences.from(argv: ["usage", "--format", "toon"])
        #expect(spaceForm.toonRequested)
        #expect(spaceForm.format == .json)
        #expect(spaceForm.usesJSONOutput)

        let equalsForm = CLIOutputPreferences.from(argv: ["usage", "--format=toon"])
        #expect(equalsForm.toonRequested)
        #expect(equalsForm.format == .json)

        let notRequested = CLIOutputPreferences.from(argv: ["usage", "--format", "json"])
        #expect(!notRequested.toonRequested)
        #expect(notRequested.format == .json)
    }

    @Test
    func `explicit toon format wins over a json shortcut in argv bootstrap`() {
        let toonThenJSON = CLIOutputPreferences.from(argv: ["usage", "--format", "toon", "--json"])
        #expect(toonThenJSON.toonRequested)
        #expect(toonThenJSON.format == .json)

        let jsonThenToon = CLIOutputPreferences.from(argv: ["usage", "--json", "--format", "toon"])
        #expect(jsonThenToon.toonRequested)
        #expect(jsonThenToon.format == .json)
    }

    @Test
    func `a later explicit format overrides an earlier toon request`() {
        let output = CLIOutputPreferences.from(argv: ["usage", "--format", "toon", "--format", "json"])
        #expect(!output.toonRequested)
        #expect(output.format == .json)
    }

    @Test
    func `parse failure argv bootstrap matches explicit format precedence for toon plus json`() {
        let output = CLIOutputPreferences.from(argv: ["usage", "--format", "toon", "--json", "--bogus"])
        #expect(output.toonRequested)
        #expect(output.format == .json)
    }

    @Test
    func `toon is recognized for usage and ignored for every other command`() {
        let values = ParsedValues(positional: [], options: ["format": ["toon"]], flags: [])

        let usage = CodexBarCLI.resolveUsageOutputPreferences(from: values)
        #expect(usage.toonRequested)
        #expect(usage.format == .json)

        // cost, cache, config, hooks, and diagnose share this constructor and advertise only
        // `text | json`, so `toon` has to stay an unrecognized value there instead of meaning JSON.
        let other = CLIOutputPreferences.from(values: values)
        #expect(!other.toonRequested)
        #expect(other.format == .text)
        #expect(!other.usesJSONOutput)
    }

    @Test
    func `toon does not change the decoded format of non usage commands`() {
        let toonOnly = ParsedValues(positional: [], options: ["format": ["toon"]], flags: [])
        #expect(CodexBarCLI._decodeFormatForTesting(from: toonOnly) == .text)

        // An unrecognized --format still loses to nothing, so --json keeps deciding the format.
        let toonWithJSONShortcut = ParsedValues(positional: [], options: ["format": ["toon"]], flags: ["json"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: toonWithJSONShortcut) == .json)

        // An unrelated unsupported value behaves identically, which is the pre-TOON contract.
        let unsupported = ParsedValues(positional: [], options: ["format": ["xml"]], flags: [])
        #expect(CodexBarCLI._decodeFormatForTesting(from: unsupported) == .text)
    }

    @Test
    func `argv bootstrap only recognizes toon for the usage command`() {
        for command in ["cost", "cache", "config", "hooks", "diagnose", "guard", "serve"] {
            let output = CLIOutputPreferences.from(argv: [command, "--format", "toon"])
            #expect(!output.toonRequested, "\(command) must not accept --format toon")
            #expect(output.format == .text, "\(command) must keep its pre-TOON default format")

            let equalsForm = CLIOutputPreferences.from(argv: [command, "--format=toon", "--json"])
            #expect(!equalsForm.toonRequested, "\(command) must not accept --format=toon")
            #expect(equalsForm.format == .json, "\(command) must still honor --json")
        }

        // `effectiveArgv` routes a bare `codexbar --format toon` to the implicit usage command.
        let implicitUsage = CLIOutputPreferences.from(argv: ["--format", "toon"])
        #expect(implicitUsage.toonRequested)
        #expect(implicitUsage.format == .json)
    }

    @Test
    func `cli error payload is JSON array`() throws {
        let payload = CodexBarCLI.makeCLIErrorPayload(
            message: "Nope",
            code: .failure,
            kind: .args,
            pretty: false)
        #expect(payload != nil)
        let data = payload?.data(using: .utf8) ?? Data()
        let json = try JSONSerialization.jsonObject(with: data) as? [Any]
        #expect(json?.isEmpty == false)
        let first = json?.first as? [String: Any]
        #expect(first?["provider"] as? String == "cli")
        let error = first?["error"] as? [String: Any]
        #expect(error?["message"] as? String == "Nope")
    }

    @Test
    func `exit omits generic error when command already emitted payload`() {
        #expect(!CodexBarCLI.shouldPrintExitError(code: .success, message: nil))
        #expect(!CodexBarCLI.shouldPrintExitError(code: .failure, message: nil))
        #expect(CodexBarCLI.shouldPrintExitError(code: .failure, message: "Nope"))
    }

    @Test
    func `text renderer includes Claude extra usage balance`() {
        let now = Date(timeIntervalSince1970: 0)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 5,
                limit: 20,
                currencyCode: "USD",
                period: "Monthly cap",
                balance: 100,
                updatedAt: now),
            updatedAt: now)

        let text = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Claude (web)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Extra usage balance: $100.00"))
    }

    @Test
    func `text renderer does not show zero cost for Claude balance only snapshot`() {
        let now = Date(timeIntervalSince1970: 0)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage",
                balance: 100,
                updatedAt: now),
            updatedAt: now)

        let text = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Claude (web)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Extra usage balance: $100.00"))
        #expect(!text.contains("Cost: 0.0 / 0.0"))
    }
}
