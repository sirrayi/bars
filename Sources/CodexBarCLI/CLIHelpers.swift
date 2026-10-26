import CodexBarCore
import Commander
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
#if os(macOS)
import CoreFoundation
#endif

extension CodexBarCLI {
    static func decodeProvider(from values: ParsedValues, config: CodexBarConfig) -> ProviderSelection {
        let rawOverride = values.options["provider"]?.last
        return Self.providerSelection(
            rawOverride: rawOverride,
            enabled: config.enabledProviders().compactMap(\.firstPartyProvider))
    }

    static func providerSelection(rawOverride: String?, enabled: [UsageProvider]) -> ProviderSelection {
        if let rawOverride, let parsed = ProviderSelection(argument: rawOverride) {
            return parsed
        }
        if enabled.count == 2 {
            let enabledSet = Set(enabled)
            let primary = Set(ProviderDescriptorRegistry.all.filter(\ .metadata.isPrimaryProvider).map(\ .id))
            if !primary.isEmpty, enabledSet == primary {
                return .both
            }
            return .custom(enabled)
        }
        if enabled.count >= 3 {
            return .custom(enabled)
        }
        if let first = enabled.first {
            return ProviderSelection(provider: first)
        }
        return .custom([])
    }

    static func decodeFormat(from values: ParsedValues) -> OutputFormat {
        CLIOutputPreferences.resolveOutputFormat(from: values).format
    }

    static func decodeTokenAccountSelection(from values: ParsedValues) throws -> TokenAccountCLISelection {
        let label = values.options["account"]?.last
        let rawIndex = values.options["accountIndex"]?.last
        var index: Int?
        if let rawIndex {
            guard let parsed = Int(rawIndex), parsed > 0 else {
                throw CLIArgumentError("--account-index must be a positive integer.")
            }
            index = parsed - 1
        }
        let allAccounts = values.flags.contains("allAccounts")
        return TokenAccountCLISelection(label: label, index: index, allAccounts: allAccounts)
    }

    static func shouldUseColor(noColor: Bool, format: OutputFormat) -> Bool {
        guard format == .text else { return false }
        if noColor {
            return false
        }
        let env = ProcessInfo.processInfo.environment
        if env["TERM"]?.lowercased() == "dumb" {
            return false
        }
        return isatty(STDOUT_FILENO) == 1
    }

    static func detectVersion(for provider: UsageProvider, browserDetection: BrowserDetection) -> String? {
        ProviderDescriptorRegistry.descriptor(for: provider).cli.versionDetector?(browserDetection)
    }

    static func normalizeVersion(raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let match = raw.range(of: #"(\d+(?:\.\d+)+)"#, options: .regularExpression) {
            return String(raw[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeHeader(provider: UsageProvider, version: String?, source: String) -> String {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        if let version, !version.isEmpty {
            return "\(name) \(version) (\(source))"
        }
        return "\(name) (\(source))"
    }

    static func printFetchAttempts(provider: UsageProvider, attempts: [ProviderFetchAttempt]) {
        guard !attempts.isEmpty else { return }
        self.writeStderr("[\(provider.rawValue)] fetch strategies:\n")
        for attempt in attempts {
            let kindLabel = ProviderDiagnosticFetchAttempt.kindLabel(attempt.kind)
            var line = "  - \(attempt.strategyID) (\(kindLabel))"
            line += attempt.wasAvailable ? " available" : " unavailable"
            if let error = attempt.errorDescription, !error.isEmpty {
                line += " error=\(error)"
            }
            self.writeStderr("\(line)\n")
        }
    }

    static func usageTextNotes(
        provider: UsageProvider,
        sourceMode: ProviderSourceMode,
        resolvedSourceLabel: String,
        dataConfidence: UsageDataConfidence = .unknown) -> [String]
    {
        // Provider-specific by design: OpenCode Go local quota windows need an explicit authority warning.
        if provider == .opencodego, dataConfidence == .estimated {
            return ["Quota estimated from local usage history"]
        }

        return []
    }

    static func fetchStatus(
        for provider: UsageProvider,
        transport: any ProviderHTTPTransport = ProviderHTTPClient(session: .shared)) async -> ProviderStatusPayload?
    {
        let urlString = ProviderDescriptorRegistry.descriptor(for: provider).metadata.statusPageURL
        guard let urlString,
              let baseURL = URL(string: urlString) else { return nil }
        do {
            let status = try await ProviderStatusFetcher.fetchStatus(from: baseURL, transport: transport)
            return ProviderStatusPayload(
                indicator: status.indicator,
                description: status.description,
                updatedAt: status.updatedAt,
                url: urlString)
        } catch {
            return ProviderStatusPayload(
                indicator: .unknown,
                description: error.localizedDescription,
                updatedAt: nil,
                url: urlString)
        }
    }

    static func resetTimeDisplayStyleFromDefaults() -> ResetTimeDisplayStyle {
        (self.boolFromAppDefaults("resetTimesShowAbsolute") ?? false) ? .absolute : .countdown
    }

    static func weeklyProgressWorkDaysFromDefaults() -> Int? {
        let domains = [
            "com.steipete.codexbar",
            "com.steipete.codexbar.debug",
        ]
        for domain in domains {
            #if os(macOS)
            let cfDomain = domain as CFString
            CFPreferencesSynchronize(cfDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            if let cfValue = CFPreferencesCopyValue(
                "weeklyProgressWorkDays" as CFString,
                cfDomain,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost) as? Int
            {
                return cfValue
            }
            #endif
            if let value = UserDefaults(suiteName: domain)?.object(forKey: "weeklyProgressWorkDays") as? Int {
                return value
            }
        }
        return UserDefaults.standard.object(forKey: "weeklyProgressWorkDays") as? Int
    }

    /// The app's "Hide personal information" privacy toggle. Read per request so the
    /// serve dashboard follows the setting without a restart, the same way reset style
    /// and weekly work days already do.
    static func hidePersonalInfoFromDefaults() -> Bool {
        self.boolFromAppDefaults("hidePersonalInfo") ?? false
    }

    /// The app's "Usage bars fill" preference (true = as used, false = as remaining). Read
    /// per request so the serve dashboard follows the setting without a restart.
    static func usageBarsShowUsedFromDefaults() -> Bool {
        self.boolFromAppDefaults("usageBarsShowUsed") ?? false
    }

    static func boolFromAppDefaults(_ key: String) -> Bool? {
        self.valueFromAppDefaults(key)
    }

    static func stringFromAppDefaults(_ key: String) -> String? {
        let value: String? = self.valueFromAppDefaults(key)
        return value?.isEmpty == false ? value : nil
    }

    static func valueFromAppDefaults<Value>(_ key: String) -> Value? {
        for domain in ["com.steipete.codexbar", "com.steipete.codexbar.debug"] {
            #if os(macOS)
            let cfDomain = domain as CFString
            CFPreferencesSynchronize(cfDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            if let value = CFPreferencesCopyValue(
                key as CFString, cfDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Value,
                (value as? String)?.isEmpty != true
            {
                return value
            }
            #endif
            if let value = UserDefaults(suiteName: domain)?.object(forKey: key) as? Value,
               (value as? String)?.isEmpty != true { return value }
        }
        return UserDefaults.standard.object(forKey: key) as? Value
    }

    static func costReportingPeriodFromDefaults() -> CostReportingPeriod {
        .migrated(
            rawValue: self.stringFromAppDefaults(CostReportingPeriod.defaultsKey),
            legacyDays: self.valueFromAppDefaults(CostReportingPeriod.legacyDaysKey))
    }

    static func fetchProviderUsage(
        provider: UsageProvider,
        context: ProviderFetchContext) async -> ProviderFetchOutcome
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        if !descriptor.fetchPlan.sourceModes.contains(context.sourceMode) {
            let error = SourceSelectionError.unsupported(
                provider: descriptor.cli.name,
                source: context.sourceMode)
            return ProviderFetchOutcome(result: .failure(error), attempts: [])
        }
        return await descriptor.fetchOutcome(context: context)
    }

    private enum SourceSelectionError: LocalizedError {
        case unsupported(provider: String, source: ProviderSourceMode)

        var errorDescription: String? {
            switch self {
            case let .unsupported(provider, source):
                "Source '\(source.rawValue)' is not supported for \(provider)."
            }
        }
    }

    static func decodeWebTimeout(from values: ParsedValues) throws -> TimeInterval? {
        guard let raw = values.options["webTimeout"]?.last else { return nil }
        guard let seconds = Double(raw),
              seconds.isFinite,
              seconds >= 0,
              seconds <= TimeInterval(Int64.max)
        else {
            throw CLIArgumentError("--web-timeout must be a finite, nonnegative number within the supported range.")
        }
        return seconds
    }

    static func decodeSourceMode(from values: ParsedValues) -> ProviderSourceMode? {
        if values.flags.contains("web") {
            return .web
        }
        guard let raw = values.options["source"]?.last?.lowercased() else { return nil }
        return ProviderSourceMode(rawValue: raw)
    }

    static func mapError(_ error: Error) -> ExitCode {
        switch error {
        case TTYCommandRunner.Error.binaryNotFound,
             ClaudeUsageError.claudeNotInstalled:
            ExitCode(2)
        case TTYCommandRunner.Error.timedOut,
             ClaudeWebFetchStrategyError.timedOut,
             CostUsageError.timedOut:
            ExitCode(4)
        case ClaudeUsageError.parseFailed,
             ClaudeUsageError.oauthFailed,
             CostUsageError.unsupportedProvider:
            ExitCode(3)
        default:
            .failure
        }
    }

    static func loadConfig(output: CLIOutputPreferences) -> CodexBarConfig {
        let store = CodexBarConfigStore()
        do {
            if let existing = try store.load() {
                return existing
            }
            return CodexBarConfig.makeDefault()
        } catch {
            if output.usesJSONOutput {
                let payload = ProviderPayload(
                    providerID: "cli",
                    account: nil,
                    version: nil,
                    source: "cli",
                    status: nil,
                    usage: nil,
                    credits: nil,
                    error: self.makeErrorPayload(code: .failure, message: error.localizedDescription, kind: .config))
                self.printProviderPayloads([payload], output: output)
            } else {
                self.writeStderr("Error: \(error.localizedDescription)\n")
            }
            Self.platformExit(ExitCode.failure.rawValue)
        }
    }
}

struct CLIArgumentError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        self.message
    }
}

#if DEBUG
extension CodexBarCLI {
    static func _usageSignatureForTesting() -> CommandSignature {
        CommandSignature.describe(UsageOptions()).flattened()
    }

    static func _costSignatureForTesting() -> CommandSignature {
        CommandSignature.describe(CostOptions()).flattened()
    }

    static func _cacheSignatureForTesting() -> CommandSignature {
        CommandSignature.describe(CacheOptions()).flattened()
    }

    static func _diagnoseSignatureForTesting() -> CommandSignature {
        CommandSignature.describe(DiagnoseOptions()).flattened()
    }

    static func _configSetAPIKeySignatureForTesting() -> CommandSignature {
        CommandSignature.describe(ConfigSetAPIKeyOptions()).flattened()
    }

    static func _configDumpSignatureForTesting() -> CommandSignature {
        CommandSignature.describe(ConfigDumpOptions()).flattened()
    }

    static func _configProviderToggleSignatureForTesting() -> CommandSignature {
        CommandSignature.describe(ConfigProviderToggleOptions()).flattened()
    }

    static func _decodeFormatForTesting(from values: ParsedValues) -> OutputFormat {
        self.decodeFormat(from: values)
    }

    static func _decodeWebTimeoutForTesting(from values: ParsedValues) throws -> TimeInterval? {
        try self.decodeWebTimeout(from: values)
    }

    static func _decodeSourceModeForTesting(from values: ParsedValues) -> ProviderSourceMode? {
        self.decodeSourceMode(from: values)
    }
}
#endif
