import CodexBarCore
import Foundation

struct ProviderSpec {
    let style: IconStyle
    let isEnabled: @MainActor () -> Bool
    let descriptor: ProviderDescriptor
    let makeFetchContext: @MainActor () -> ProviderFetchContext
}

struct ProviderRegistry {
    let metadata: [UsageProvider: ProviderMetadata]

    static let shared: ProviderRegistry = .init()

    init(metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) {
        self.metadata = metadata
    }

    @MainActor
    func specs(
        settings: SettingsStore,
        metadata: [UsageProvider: ProviderMetadata],
        claudeFetcher: any ClaudeUsageFetching,
        browserDetection: BrowserDetection,
        environmentBase: [String: String] = ProcessInfo.processInfo.environment) -> [UsageProvider: ProviderSpec]
    {
        var specs: [UsageProvider: ProviderSpec] = [:]
        specs.reserveCapacity(UsageProvider.allCases.count)

        for provider in UsageProvider.allCases {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            let meta = metadata[provider]!
            let spec = ProviderSpec(
                style: descriptor.branding.iconStyle,
                isEnabled: { settings.isProviderEnabled(provider: provider, metadata: meta) },
                descriptor: descriptor,
                makeFetchContext: {
                    let account = ProviderTokenAccountSelection.selectedAccount(
                        provider: provider,
                        settings: settings,
                        override: nil)
                    let sourceMode = Self.resolvedSourceMode(
                        provider: provider,
                        settings: settings,
                        account: account)

                    let snapshot = Self.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
                    let env = Self.makeEnvironment(
                        base: environmentBase,
                        provider: provider,
                        settings: settings,
                        tokenOverride: nil)
                    let verbose = settings.isVerboseLoggingEnabled
                    return ProviderFetchContext(
                        runtime: .app,
                        sourceMode: sourceMode,
                        includeCredits: false,
                        includeOptionalUsage:
                        ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
                            provider: provider,
                            settings: settings,
                            override: nil),
                        includeAccountIdentity: settings.accountWidgetsEnabled && account != nil,
                        webTimeout: 60,
                        webDebugDumpHTML: false,
                        verbose: verbose,
                        env: env,
                        settings: snapshot,
                        claudeFetcher: claudeFetcher,
                        browserDetection: browserDetection,
                        selectedTokenAccountID: account?.id,
                        tokenAccountTokenUpdater: { provider, accountID, token in
                            await MainActor.run {
                                settings.updateTokenAccount(
                                    provider: provider,
                                    accountID: accountID,
                                    token: token)
                            }
                        },
                        providerManualTokenUpdater: nil,
                        costUsageHistoryDays: settings.costUsageHistoryDays,
                        persistsCLISessions: true,
                        persistentCLISessionIdleWindow: Self.persistentCLISessionIdleWindow(
                            refreshInterval: Self.nominalRefreshInterval(
                                for: settings.refreshFrequency)))
                })
            specs[provider] = spec
        }

        return specs
    }

    static func persistentCLISessionIdleWindow(refreshInterval: TimeInterval?) -> TimeInterval {
        max(180, (refreshInterval ?? 120) + 60)
    }

    /// `RefreshFrequency.seconds` is nil for `.adaptive`, which would collapse the idle window to
    /// its floor and churn persistent CLI sessions between adaptive ticks. No `UsageStore` exists
    /// when specs are built, so `.adaptive` maps to the policy's nominal interval instead of a
    /// live decision; `.manual` stays nil.
    static func nominalRefreshInterval(for frequency: RefreshFrequency) -> TimeInterval? {
        frequency.usesAdaptivePolicy
            ? AdaptiveRefreshPolicy.nominalIntervalForHeuristics : frequency.seconds
    }

    @MainActor
    static func resolvedSourceMode(
        provider: UsageProvider,
        settings: SettingsStore,
        account: ProviderTokenAccount?) -> ProviderSourceMode
    {
        let base =
            ProviderCatalog.implementation(for: provider)?
                .sourceMode(context: ProviderSourceModeContext(provider: provider, settings: settings))
                ?? .auto
        let config = settings.configSnapshot.providerConfig(for: provider.instanceID)
        return ProviderDescriptorRegistry.descriptor(for: provider).credentials?
            .selectedAccountSourceMode(base: base, account: account, config: config) ?? base
    }

    @MainActor
    static func makeSettingsSnapshot(
        settings: SettingsStore,
        tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    {
        var builder = ProviderSettingsSnapshotBuilder(
            debugMenuEnabled: settings.debugMenuEnabled,
            debugKeepCLISessionsAlive: settings.debugKeepCLISessionsAlive)
        let context = ProviderSettingsSnapshotContext(
            settings: settings,
            tokenOverride: tokenOverride)
        for implementation in ProviderCatalog.all {
            let registration = ProviderDescriptorRegistry.descriptor(for: implementation.id)
                .settingsSection
            guard let contribution = implementation.settingsSnapshot(context: context) else {
                preconditionFailure(
                    "Missing settings snapshot section for provider '\(implementation.id.rawValue)'")
            }
            guard registration.accepts(contribution) else {
                preconditionFailure(
                    "Mismatched settings snapshot section for provider '\(implementation.id.rawValue)'")
            }
            builder.apply(contribution)
        }
        return builder.build()
    }

    @MainActor
    static func makeEnvironment(
        base: [String: String],
        provider: UsageProvider,
        settings: SettingsStore,
        tokenOverride: TokenAccountOverride?) -> [String: String]
    {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: provider,
            settings: settings,
            override: tokenOverride)
        return ProviderEnvironmentResolver.resolve(
            base: base,
            provider: provider,
            config: settings.providerConfig(for: provider),
            selectedAccount: account)
    }
}
