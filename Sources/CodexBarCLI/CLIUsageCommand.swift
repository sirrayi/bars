import CodexBarCore
import Commander
import Foundation

struct UsageCommandContext {
    let format: OutputFormat
    let includeCredits: Bool
    var sourceModeOverride: ProviderSourceMode?
    let webDebugDumpHTML: Bool
    let webTimeout: TimeInterval
    let verbose: Bool
    let useColor: Bool
    let resetStyle: ResetTimeDisplayStyle
    let weeklyWorkDays: Int?
    let jsonOnly: Bool
    let claudeFetcher: ClaudeUsageFetcher
    let browserDetection: BrowserDetection
    /// A verifier-only route that invokes the same app provider pipeline while retaining CLI JSON output.
    var providerRuntime: ProviderRuntime = .cli
    /// True for long-lived hosts (`codexbar serve`) that keep warm provider
    /// helper sessions alive between fetches instead of resetting after each one-shot fetch.
    var persistCLISessions: Bool = false
    var persistentCLISessionIdleWindow: TimeInterval?
    var cardsLayout: Bool = false
    var sourceLabelSuffix = ""
    /// Serves the menu bar app's cached usage after a locked-keychain fetch failure (SSH sessions, opt-in).
    var usageCacheFallback: (@Sendable (UsageProvider, _ lockedKeychainObserved: Bool, _ terminalError: Error)
        -> CLIUsageCache.Hit?)?

    func withUsageCacheFallback(config: CodexBarConfig) -> UsageCommandContext {
        var context = self
        context.usageCacheFallback = CLIUsageCache.fallbackReader(config: config)
        return context
    }
}

struct UsageCommandOutput {
    var sections: [String] = []
    var payload: [ProviderPayload] = []
    var cards: [CLICardModel] = []
    var cardFailures: [CLICardFailure] = []
    var exitCode: ExitCode = .success
}

private struct UsageSuccessRenderInput {
    let provider: UsageProvider
    let accountLabel: String?
    let cacheAccountKey: String?
    let version: String?
    let source: String
    let status: ProviderStatusPayload?
    let usage: UsageSnapshot
    let credits: CreditsSnapshot?
    let command: UsageCommandContext
    let diagnostic: String?
    let notes: [String]
    /// Set when the usage came from the menu bar app's cache: seconds since its fetch.
    var ageSeconds: Int?
}

extension UsageCommandOutput {
    mutating func merge(_ other: UsageCommandOutput) {
        self.sections.append(contentsOf: other.sections)
        self.payload.append(contentsOf: other.payload)
        self.cards.append(contentsOf: other.cards)
        self.cardFailures.append(contentsOf: other.cardFailures)
        if other.exitCode != .success {
            self.exitCode = other.exitCode
        }
    }
}

extension CodexBarCLI {
    static func runUsage(_ values: ParsedValues) async {
        let output = Self.resolveUsageOutputPreferences(from: values)
        let config = Self.loadConfig(output: output)
        let provider = Self.decodeProvider(from: values, config: config)
        let providerList = provider.asList
        let setup = Self.usageFetchSetup(values: values, providers: providerList, output: output)
        let command = setup.command.withUsageCacheFallback(config: config)
        let tokenContext = setup.tokenContext(config: config, output: output)
        let appAutoVerifier = command.providerRuntime == .app
        let includeStatus = setup.includeStatus
        let result = await Self.collectUsageOutputs(providers: providerList) { provider in
            await Self.fetchSingleProviderUsageOutput(
                provider: provider,
                includeStatus: includeStatus,
                appAutoVerifier: appAutoVerifier,
                tokenContext: tokenContext,
                command: command)
        }

        Self.printUsageOutput(
            format: command.format,
            toonRequested: output.toonRequested,
            sections: result.sections,
            payload: result.payload,
            pretty: output.pretty)

        Self.exit(code: result.exitCode, output: output, kind: result.exitCode == .success ? .runtime : .provider)
    }

    /// Bound provider I/O while preserving the sequential command's output and failure precedence.
    static func collectUsageOutputs(
        providers: [UsageProvider],
        fetch: @escaping @Sendable (UsageProvider) async -> UsageCommandOutput) async -> UsageCommandOutput
    {
        await withTaskGroup(of: (Int, UsageCommandOutput, String).self) { group in
            func enqueue(_ index: Int) {
                group.addTask {
                    let diagnostics = CLIStderrBuffer()
                    let output = await Self.$stderrBuffer.withValue(diagnostics) {
                        // CLI fetching must not clear Keychain cooldowns or authorize prompts.
                        await ProviderInteractionContext.$current.withValue(.background) {
                            await fetch(providers[index])
                        }
                    }
                    return (index, output, diagnostics.contents)
                }
            }
            var next = min(providers.count, 3)
            for index in 0..<next {
                enqueue(index)
            }
            var results: [(Int, UsageCommandOutput, String)] = []
            for await result in group {
                results.append(result)
                if next < providers.count {
                    enqueue(next)
                    next += 1
                }
            }
            var output = UsageCommandOutput()
            for (_, result, diagnostics) in results.sorted(by: { $0.0 < $1.0 }) {
                Self.writeStderr(diagnostics)
                output.merge(result)
            }
            return output
        }
    }

    static func fetchSingleProviderUsageOutput(
        provider: UsageProvider,
        includeStatus: Bool,
        appAutoVerifier: Bool,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext) async -> UsageCommandOutput
    {
        let status = includeStatus ? await Self.fetchStatus(for: provider) : nil
        if appAutoVerifier {
            // Background app Auto intentionally launches the opaque Claude owner CLI only after a successful
            // user-initiated fetch has established this process's account-scoped availability marker. Recreate
            // that real app lifecycle before exercising the background route; discard the foreground payload.
            var establishmentCommand = command
            establishmentCommand.sourceModeOverride = .cli
            let establishment = await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await Self.fetchUsageOutputs(
                    provider: provider,
                    status: status,
                    tokenContext: tokenContext,
                    command: establishmentCommand)
            }
            if establishment.exitCode != .success {
                return establishment
            }
        }
        var command = command
        // Provider-specific by design: one-shot Claude Auto usage follows the adapter's active slot.
        let config = tokenContext.config.providerConfig(for: .claude)
        if !appAutoVerifier, CLIClaudeSwapCards.isEligible(
            provider: provider,
            integrationEnabled: config?.claudeSwapEnabled == true,
            hasExplicitAccountSelection: tokenContext.selection.usesOverride,
            sourceModeOverride: command.sourceModeOverride ?? tokenContext.preferredSourceMode(for: provider))
        {
            let source = config?.resolvedClaudeSwapSource ?? .claudeSwap
            if let list = try? await ClaudeSwapAccountReader.readAccountList(
                executablePath: CLIClaudeSwapCards.executablePath(from: config), source: source),
                let active = ClaudeSwapAccountProjection.accountSnapshots(
                    from: list,
                    source: source,
                    previousAccounts: ClaudeSwapRetainedUsageStore.load()).first(where: \.isActive),
                let usage = active.snapshot
            {
                let diagnostic = active.error.map(CLIClaudeSwapText.sanitizeDiagnostic)
                var result = UsageCommandOutput()
                Self.appendSuccessRenderOutput(
                    UsageSuccessRenderInput(
                        provider: provider,
                        accountLabel: CLIClaudeSwapText.sanitizeLabel(active.displayLabel),
                        cacheAccountKey: nil,
                        version: nil,
                        source: source.label,
                        status: status,
                        usage: usage,
                        credits: nil,
                        command: command,
                        diagnostic: diagnostic,
                        notes: diagnostic.map { [$0] } ?? []),
                    output: &result)
                return result
            }
            command.sourceLabelSuffix = " (\(source.label) fallback)"
        }
        return await Self.fetchUsageOutputs(
            provider: provider,
            status: status,
            tokenContext: tokenContext,
            command: command)
    }

    /// TOON piggybacks on the JSON fetch/render pipeline (same data, denser rendering at print time)
    /// rather than being a first-class `OutputFormat` case, so it doesn't ripple into every other
    /// command's exhaustive `switch format` sites. `toonRequested` also travels on the returned
    /// preferences so early-exit error paths (`Self.exit`, `Self.loadConfig`) render TOON instead of
    /// silently falling back to JSON. `allowsToon` is opt-in here and nowhere else: `cost`, `cache`,
    /// `config`, `hooks`, and `diagnose` advertise only `text | json`, so they keep the legacy
    /// decoder that ignores unrecognized `--format` values.
    static func resolveUsageOutputPreferences(from values: ParsedValues) -> CLIOutputPreferences {
        CLIOutputPreferences.from(values: values, allowsToon: true)
    }

    private static func printUsageOutput(
        format: OutputFormat,
        toonRequested: Bool,
        sections: [String],
        payload: [ProviderPayload],
        pretty: Bool)
    {
        if toonRequested {
            print(ToonFormatter.encode(payload))
            return
        }
        switch format {
        case .text:
            if !sections.isEmpty {
                print(sections.joined(separator: "\n\n"))
            }
        case .json:
            printJSON(payload, pretty: pretty)
        }
    }

    static func appAutoVerifierArgumentError(
        enabled: Bool,
        providers: [UsageProvider],
        sourceMode: ProviderSourceMode?,
        tokenSelection: TokenAccountCLISelection) -> String?
    {
        guard enabled else { return nil }
        // Provider-specific by design: this hidden verifier recreates Claude's owner-CLI lifecycle only.
        guard providers == [.claude], sourceMode == .auto else {
            return "--app-auto-verifier requires --provider claude --source auto."
        }
        guard !tokenSelection.usesOverride else {
            return "--app-auto-verifier does not accept token-account selection."
        }
        return nil
    }

    static func fetchUsageOutputs(
        provider: UsageProvider,
        status: ProviderStatusPayload?,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext,
        publishPartial: CLIServeOperationCoordinator<UsageCommandOutput>
            .PublishPartial? = nil) async -> UsageCommandOutput
    {
        let accounts: [ProviderTokenAccount]
        do {
            accounts = try tokenContext.resolvedAccounts(
                for: provider,
                sourceMode: command.sourceModeOverride ?? tokenContext.preferredSourceMode(for: provider))
        } catch {
            return Self.usageOutputForAccountResolutionError(
                provider: provider,
                status: status,
                command: command,
                error: error)
        }

        let selections: [ProviderTokenAccount?] = accounts.isEmpty ? [nil] : accounts.map { Optional($0) }
        let data = tokenContext.accountsByProvider[provider]
        let activeID = data.flatMap { $0.accounts.isEmpty ? nil : $0.accounts[$0.clampedActiveIndex()].id }
        return await Self.collectAccountUsage(
            provider: provider,
            accounts: selections.map { account in
                account.map { .token($0, active: $0.id == activeID) }
            },
            minimumDelay: TokenAccountSupportCatalog.support(for: provider)?.minimumDelayBetweenAccountRefreshes,
            publishPartial: publishPartial)
        { index in
            await Self.fetchUsageOutput(
                provider: provider,
                account: selections[index],
                status: status,
                tokenContext: tokenContext,
                command: command)
        }
    }

    private static func usageOutputForAccountResolutionError(
        provider: UsageProvider,
        status: ProviderStatusPayload?,
        command: UsageCommandContext,
        error: Error) -> UsageCommandOutput
    {
        var output = UsageCommandOutput()
        output.exitCode = .failure
        if command.format == .json {
            output.payload.append(Self.makeProviderErrorPayload(
                provider: provider,
                account: nil,
                source: (command.sourceModeOverride?.rawValue ?? "auto") + command.sourceLabelSuffix,
                status: status,
                error: error,
                kind: .provider))
        } else if command.cardsLayout {
            output.cardFailures.append(CLICardFailure(
                provider: provider,
                accountLabel: nil,
                message: error.localizedDescription))
        } else if !command.jsonOnly {
            Self.writeStderr("Error: \(error.localizedDescription)\n")
        }
        return output
    }

    private static func appendSuccessRenderOutput(
        _ input: UsageSuccessRenderInput,
        output: inout UsageCommandOutput)
    {
        switch input.command.format {
        case .text:
            if input.command.cardsLayout {
                output.cards.append(CLICardsRenderer.makeCard(CLICardBuildInput(
                    provider: input.provider,
                    snapshot: input.usage,
                    credits: input.credits,
                    source: input.source,
                    status: input.status,
                    notes: input.notes,
                    useColor: input.command.useColor,
                    resetStyle: input.command.resetStyle,
                    weeklyWorkDays: input.command.weeklyWorkDays,
                    now: Date())))
            } else {
                let text = CLIRenderer.renderText(
                    provider: input.provider,
                    snapshot: input.usage,
                    credits: input.credits,
                    context: RenderContext(
                        header: Self.makeHeader(
                            provider: input.provider,
                            version: input.version,
                            source: input.source),
                        status: input.status,
                        useColor: input.command.useColor,
                        resetStyle: input.command.resetStyle,
                        weeklyWorkDays: input.command.weeklyWorkDays,
                        notes: input.notes))
                output.sections.append(text)
            }
        case .json:
            var usagePayload = ProviderPayload(
                provider: input.provider,
                account: input.accountLabel,
                cacheAccountKey: input.cacheAccountKey,
                version: input.version,
                source: input.source,
                status: input.status,
                usage: input.usage,
                credits: input.credits,
                error: nil,
                diagnostic: input.diagnostic,
                pace: CLIRenderer.providerPacePayload(
                    provider: input.provider, snapshot: input.usage, weeklyWorkDays: input.command.weeklyWorkDays))
            usagePayload.ageSeconds = input.ageSeconds
            output.payload.append(usagePayload)
        }
    }

    private static func fetchUsageOutput(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        status: ProviderStatusPayload?,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext) async -> UsageCommandOutput
    {
        var output = UsageCommandOutput()
        let env = tokenContext.environment(
            base: tokenContext.baseEnvironment,
            provider: provider,
            account: account)
        let settings = tokenContext.settingsSnapshot(for: provider, account: account)
        let configSource = tokenContext.preferredSourceMode(for: provider)
        let baseSource = command.sourceModeOverride ?? configSource
        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: baseSource,
            provider: provider,
            account: account)
        let cacheAccountKey = Self.usageCacheAccountKey(account: account)
        let fetchContext = ProviderFetchContext(
            runtime: command.providerRuntime,
            sourceMode: effectiveSourceMode,
            includeCredits: command.includeCredits,
            requiresOptionalUsageCompleteness: true,
            webTimeout: command.webTimeout,
            webDebugDumpHTML: command.webDebugDumpHTML,
            verbose: command.verbose,
            env: env,
            settings: settings,
            claudeFetcher: command.claudeFetcher,
            browserDetection: command.browserDetection,
            selectedTokenAccountID: account?.id,
            tokenAccountTokenUpdater: tokenContext.tokenUpdater(for: account),
            providerManualTokenUpdater: tokenContext.manualTokenUpdater(),
            persistsCLISessions: Self.persistsCLISessions(command: command),
            persistentCLISessionIdleWindow: command.persistentCLISessionIdleWindow)
        let (outcome, lockedKeychainObserved) = await CLIUsageCache.observingLockedKeychain {
            await Self.fetchProviderUsage(provider: provider, context: fetchContext)
        }
        if command.verbose, !command.jsonOnly {
            Self.printFetchAttempts(provider: provider, attempts: outcome.attempts)
        }

        switch outcome.result {
        case let .success(result):
            var usage = result.usage.scoped(to: provider)
            if let account {
                usage = usage.withAccountLabel(account.label, for: provider)
            }

            let shouldDetectVersion = Self.shouldDetectVersion(provider: provider, result: result)
            let version = Self.normalizeVersion(
                raw: shouldDetectVersion
                    ? Self.detectVersion(for: provider, browserDetection: command.browserDetection)
                    : nil)
            let source = result.sourceLabel + command.sourceLabelSuffix
            let notes = Self.usageTextNotes(
                provider: provider,
                sourceMode: effectiveSourceMode,
                resolvedSourceLabel: source,
                dataConfidence: usage.dataConfidence) + (result.diagnostic.map { [$0] } ?? [])

            Self.appendSuccessRenderOutput(
                UsageSuccessRenderInput(
                    provider: provider,
                    accountLabel: account?.label,
                    cacheAccountKey: cacheAccountKey,
                    version: version,
                    source: source,
                    status: status,
                    usage: usage,
                    credits: result.credits,
                    command: command,
                    diagnostic: result.diagnostic,
                    notes: notes),
                output: &output)
        case let .failure(error):
            // Only a default-account fetch without `--source` whose terminal failure is a credential-access one
            // after a locked keychain read falls back to the cache.
            if command.sourceModeOverride == nil, !tokenContext.selection.usesOverride,
               account == nil,
               let hit = command.usageCacheFallback?(provider, lockedKeychainObserved, error)
            {
                let usage = hit.entry.usage.scoped(to: provider)
                let source = "codexbar-app" + command.sourceLabelSuffix
                let appNote = "Cached by the CodexBar app (the keychain was unavailable here). "
                    + UsageFormatter.updatedString(from: usage.updatedAt)
                Self.appendSuccessRenderOutput(
                    UsageSuccessRenderInput(
                        provider: provider,
                        accountLabel: nil,
                        cacheAccountKey: nil,
                        version: nil,
                        source: source,
                        status: status,
                        usage: usage,
                        credits: nil,
                        command: command,
                        diagnostic: nil,
                        notes: Self.usageTextNotes(
                            provider: provider,
                            sourceMode: effectiveSourceMode,
                            resolvedSourceLabel: source,
                            dataConfidence: usage.dataConfidence) + [appNote],
                        ageSeconds: hit.ageSeconds),
                    output: &output)
                break
            }
            output.exitCode = Self.mapError(error)
            if command.format == .json {
                output.payload.append(Self.makeProviderErrorPayload(
                    provider: provider,
                    account: account?.label,
                    cacheAccountKey: cacheAccountKey,
                    source: effectiveSourceMode.rawValue + command.sourceLabelSuffix,
                    status: status,
                    error: error,
                    kind: .provider))
            } else if command.cardsLayout {
                output.cardFailures.append(CLICardFailure(
                    provider: provider,
                    accountLabel: account?.label,
                    message: error.localizedDescription))
            } else if !command.jsonOnly {
                if let accountLabel = account?.label {
                    Self.writeStderr(
                        "Error (\(provider.rawValue) - \(accountLabel)): \(error.localizedDescription)\n")
                } else {
                    Self.writeStderr("Error: \(error.localizedDescription)\n")
                }
            }
        }

        return await Self.finishUsageOutput(output, provider: provider, command: command)
    }

    static func shouldDetectVersion(provider: UsageProvider, result: ProviderFetchResult) -> Bool {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        guard descriptor.cli.versionDetector != nil else { return false }
        // Provider-specific by design: Claude OAuth is in-process and has no CLI version to report.
        return !(provider == .claude && result.strategyKind == .oauth)
    }

    private static func persistsCLISessions(
        command: UsageCommandContext) -> Bool
    {
        command.persistCLISessions
    }

    private static func finishUsageOutput(
        _ output: UsageCommandOutput,
        provider: UsageProvider,
        command: UsageCommandContext) async -> UsageCommandOutput
    {
        output
    }

    static func usageCacheAccountKey(account: ProviderTokenAccount?) -> String? {
        account.map { "token:\($0.id.uuidString.lowercased())" }
    }
}
