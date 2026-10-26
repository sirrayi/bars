import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runConfig(path: [String], values: ParsedValues) async {
        switch path {
        case ["config", "preferences", "export"]:
            self.runConfigPreferences(values, importing: false)
        case ["config", "preferences", "import"]:
            self.runConfigPreferences(values, importing: true)
        case ["config", "validate"]:
            self.runConfigValidate(values)
        case ["config", "dump"]:
            self.runConfigDump(values)
        case ["config", "providers"]:
            self.runConfigProviders(values)
        case ["config", "enable"]:
            self.runConfigSetProviderEnabled(values, enabled: true)
        case ["config", "disable"]:
            self.runConfigSetProviderEnabled(values, enabled: false)
        case ["config", "set-source"]:
            self.runConfigSetSource(values)
        case ["config", "set-api-key"]:
            self.runConfigSetAPIKey(values)
        default:
            self.exit(
                code: .failure,
                message: "Unknown command",
                output: CLIOutputPreferences.from(values: values),
                kind: .args)
        }
    }

    static func runConfigValidate(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let config = Self.loadConfig(output: output)
        let issues = CodexBarConfigValidator.validate(config)
        let hasErrors = issues.contains(where: { $0.severity == .error })

        switch output.format {
        case .text:
            if issues.isEmpty {
                print("Config: OK")
            } else {
                for issue in issues {
                    let provider = issue.provider?.rawValue ?? "config"
                    let field = issue.field ?? ""
                    let prefix = "[\(issue.severity.rawValue.uppercased())]"
                    let suffix = field.isEmpty ? "" : " (\(field))"
                    print("\(prefix) \(provider)\(suffix): \(issue.message)")
                }
            }
        case .json:
            Self.printJSON(issues, pretty: output.pretty)
        }

        Self.exit(code: hasErrors ? .failure : .success, output: output, kind: .config)
    }

    static func runConfigDump(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let showSecrets = values.flags.contains("showSecrets")
        let config = Self.loadConfig(output: output).sanitizedForDump(showSecrets: showSecrets)
        do {
            let data = try config.encodedData(pretty: output.pretty)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }
        Self.exit(code: .success, output: output, kind: .config)
    }

    static func runConfigProviders(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let config = Self.loadConfig(output: output)
        let results = Self.configProviderStatuses(config)

        switch output.format {
        case .text:
            for result in results {
                let state = result.enabled ? "enabled" : "disabled"
                let marker = result.defaultEnabled ? " default" : ""
                print("\(result.provider): \(state)\(marker) (\(result.displayName))")
            }
        case .json:
            Self.printJSON(results, pretty: output.pretty)
        }

        Self.exit(code: .success, output: output, kind: .config)
    }

    static func runConfigSetProviderEnabled(_ values: ParsedValues, enabled: Bool) {
        let output = CLIOutputPreferences.from(values: values)
        guard let rawProvider = values.options["provider"]?.last,
              let provider = ProviderDescriptorRegistry.cliNameMap[rawProvider.lowercased()]
        else {
            Self.exit(
                code: .failure,
                message: "Unknown or missing provider. Use --provider <name>.",
                output: output,
                kind: .args)
        }

        let store = CodexBarConfigStore()
        var config = Self.loadConfig(output: output)
        config = Self.configSettingProviderEnabled(config, provider: provider, enabled: enabled)

        do {
            try store.save(config)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }

        let metadata = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        let result = ConfigProviderToggleResult(
            provider: provider.rawValue,
            displayName: metadata.displayName,
            enabled: enabled,
            configPath: store.fileURL.path)

        switch output.format {
        case .text:
            let state = enabled ? "enabled" : "disabled"
            print("Config: \(state) \(metadata.displayName)")
        case .json:
            Self.printJSON(result, pretty: output.pretty)
        }

        Self.exit(code: .success, output: output, kind: .config)
    }

    static func unsupportedAPIKeyErrorMessage(rawProvider: String) -> String {
        "\(rawProvider) does not support config API keys."
    }

    static func runConfigSetAPIKey(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)

        guard let rawProvider = values.options["provider"]?.last,
              let provider = ProviderDescriptorRegistry.cliNameMap[rawProvider.lowercased()]
        else {
            Self.exit(
                code: .failure,
                message: "Unknown or missing provider. Use --provider <name>.",
                output: output,
                kind: .args)
        }
        guard ProviderConfigEnvironment.supportsAPIKeyOverride(for: provider) else {
            Self.exit(
                code: .failure,
                message: Self.unsupportedAPIKeyErrorMessage(rawProvider: rawProvider),
                output: output,
                kind: .args)
        }

        let apiKey: String
        do {
            apiKey = try Self.resolveConfigAPIKeyInput(
                apiKey: values.options["apiKey"]?.last,
                readFromStdin: values.flags.contains("stdin"))
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .args)
        }

        let enableProvider = !values.flags.contains("noEnable")
        let store = CodexBarConfigStore()
        var config = Self.loadConfig(output: output)
        config = Self.configSettingAPIKey(
            config,
            provider: provider,
            apiKey: apiKey,
            enableProvider: enableProvider)

        do {
            try store.save(config)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }

        let result = ConfigSetAPIKeyResult(
            provider: provider.rawValue,
            enabled: config.providerConfig(for: provider.instanceID)?.enabled ?? false,
            configPath: store.fileURL.path)

        switch output.format {
        case .text:
            let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
            let suffix = result.enabled ? " and enabled" : ""
            let action = "stored API key"
            print("Config: \(action) for \(name)\(suffix)")
        case .json:
            Self.printJSON(result, pretty: output.pretty)
        }

        Self.exit(code: .success, output: output, kind: .config)
    }

    static func resolveConfigAPIKeyInput(apiKey: String?, readFromStdin: Bool) throws -> String {
        if apiKey != nil, readFromStdin {
            throw CLIArgumentError("Use either --api-key or --stdin, not both.")
        }

        let raw: String? = if readFromStdin {
            String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
        } else {
            apiKey
        }

        guard let value = SettingsValue.cleaned(raw) else {
            throw CLIArgumentError("Missing API key. Pass --api-key <key> or pipe it with --stdin.")
        }
        return value
    }

    static func configSettingAPIKey(
        _ config: CodexBarConfig,
        provider: UsageProvider,
        apiKey: String,
        enableProvider: Bool) -> CodexBarConfig
    {
        var updated = config.normalized()
        var providerConfig = updated.providerConfig(for: provider.instanceID) ?? ProviderConfig(id: provider.instanceID)

        providerConfig.apiKey = apiKey
        if enableProvider {
            providerConfig.enabled = true
        }
        updated.setProviderConfig(providerConfig)
        return updated
    }

    static func configSettingProviderEnabled(
        _ config: CodexBarConfig,
        provider: UsageProvider,
        enabled: Bool) -> CodexBarConfig
    {
        var updated = config.normalized()
        var providerConfig = updated.providerConfig(for: provider.instanceID) ?? ProviderConfig(id: provider.instanceID)
        providerConfig.enabled = enabled
        updated.setProviderConfig(providerConfig)
        return updated
    }

    static func configProviderStatuses(_ config: CodexBarConfig) -> [ConfigProviderStatusResult] {
        let metadata = ProviderDescriptorRegistry.metadata
        var results = config.normalized().providers.map { providerConfig in
            let provider = providerConfig.id.firstPartyProvider
            let meta = provider.flatMap { metadata[$0] }
            let defaultEnabled = meta?.defaultEnabled ?? false
            return ConfigProviderStatusResult(
                provider: providerConfig.id.rawValue,
                displayName: meta?.displayName ?? providerConfig.id.rawValue,
                enabled: providerConfig.enabled ?? defaultEnabled,
                defaultEnabled: defaultEnabled)
        }
        for entry in config.unavailableProviders {
            results.insert(ConfigProviderStatusResult(
                provider: entry.id,
                displayName: "plugin (not loaded)",
                enabled: entry.enabled,
                defaultEnabled: false), at: min(entry.index, results.count))
        }
        return results
    }

    private static func cleanSingleLineConfigValue(_ raw: String?, fieldName: String) throws -> String? {
        guard let value = SettingsValue.cleaned(raw) else { return nil }
        guard !value.contains(where: \.isNewline) else {
            throw CLIArgumentError("--\(fieldName) must be a single line.")
        }
        return value
    }
}

struct ConfigOptions: CommanderParsable {
    @OptionGroup
    var common: CLICommonOptions
}

struct ConfigDumpOptions: CommanderParsable {
    @OptionGroup
    var common: CLICommonOptions

    @Flag(name: .long("show-secrets"), help: "Include raw un-redacted API keys and tokens in output")
    var showSecrets: Bool = false
}

struct ConfigSetAPIKeyOptions: CommanderParsable {
    @OptionGroup
    var common: CLICommonOptions

    @Option(name: .long("provider"), help: ProviderHelp.concreteOptionHelp)
    var provider: String?

    @Option(name: .long("api-key"), help: "API key to store")
    var apiKey: String?

    @Flag(name: .long("stdin"), help: "Read API key from stdin")
    var stdin: Bool = false

    @Flag(name: .long("no-enable"), help: "Store the key without enabling the provider")
    var noEnable: Bool = false
}

struct ConfigProviderToggleOptions: CommanderParsable {
    @OptionGroup
    var common: CLICommonOptions

    @Option(name: .long("provider"), help: ProviderHelp.concreteOptionHelp)
    var provider: String?
}

private struct ConfigSetAPIKeyResult: Encodable {
    let provider: String
    let enabled: Bool
    let configPath: String
}

struct ConfigProviderStatusResult: Encodable, Equatable {
    let provider: String
    let displayName: String
    let enabled: Bool
    let defaultEnabled: Bool
}

private struct ConfigProviderToggleResult: Encodable {
    let provider: String
    let displayName: String
    let enabled: Bool
    let configPath: String
}
