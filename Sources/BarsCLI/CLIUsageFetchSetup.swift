import BarsCore
import Commander
import Foundation

struct CLIUsageFetchSetup {
    let tokenSelection: TokenAccountCLISelection
    let includeStatus: Bool
    let command: UsageCommandContext

    init(
        values: ParsedValues,
        providers: [UsageProvider],
        output: CLIOutputPreferences,
        cardsLayout: Bool = false) throws
    {
        let sourceMode = BarsCLI.decodeSourceMode(from: values)
        if values.options["source"]?.last != nil, sourceMode == nil {
            throw CLIArgumentError("--source must be auto|web|cli|oauth|api.")
        }
        let webTimeout = try BarsCLI.decodeWebTimeout(from: values) ?? 60
        let selection = try BarsCLI.decodeTokenAccountSelection(from: values)
        if selection.allAccounts, selection.label != nil || selection.index != nil {
            throw CLIArgumentError("--all-accounts cannot be combined with --account or --account-index.")
        }
        let appAutoVerifier = !cardsLayout && values.flags.contains("appAutoVerifier")
        if let message = BarsCLI.appAutoVerifierArgumentError(
            enabled: appAutoVerifier,
            providers: providers,
            sourceMode: sourceMode,
            tokenSelection: selection)
        {
            throw CLIArgumentError(message)
        }
        if let message = selection.providerSelectionError(providers) {
            throw CLIArgumentError(message)
        }
        self.tokenSelection = selection
        self.includeStatus = values.flags.contains("status")
        let format: OutputFormat = cardsLayout ? .text : output.format
        let browserDetection = BrowserDetection()
        self.command = UsageCommandContext(
            format: format,
            includeCredits: format == .json || !values.flags.contains("noCredits"),
            sourceModeOverride: sourceMode,
            webDebugDumpHTML: values.flags.contains("webDebugDumpHtml"),
            webTimeout: webTimeout,
            verbose: values.flags.contains("verbose"),
            useColor: BarsCLI.shouldUseColor(noColor: values.flags.contains("noColor"), format: format),
            resetStyle: BarsCLI.resetTimeDisplayStyleFromDefaults(),
            weeklyWorkDays: BarsCLI.weeklyProgressWorkDaysFromDefaults(),
            jsonOnly: output.jsonOnly,
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            providerRuntime: appAutoVerifier ? .app : .cli,
            cardsLayout: cardsLayout)
    }

    func tokenContext(config: BarsConfig, output: CLIOutputPreferences) -> TokenAccountCLIContext {
        do {
            return try TokenAccountCLIContext(
                selection: self.tokenSelection,
                config: config,
                verbose: self.command.verbose,
                resolutionScope: self.command.providerRuntime == .app ? .ambientAccount : .configuredAccounts)
        } catch {
            BarsCLI.exit(
                code: .failure,
                message: "Error: \(error.localizedDescription)",
                output: output,
                kind: .config)
        }
    }
}

extension BarsCLI {
    static func usageFetchSetup(
        values: ParsedValues,
        providers: [UsageProvider],
        output: CLIOutputPreferences,
        cardsLayout: Bool = false) -> CLIUsageFetchSetup
    {
        do {
            return try CLIUsageFetchSetup(
                values: values,
                providers: providers,
                output: output,
                cardsLayout: cardsLayout)
        } catch {
            exit(code: .failure, message: "Error: \(error.localizedDescription)", output: output, kind: .args)
        }
    }
}
