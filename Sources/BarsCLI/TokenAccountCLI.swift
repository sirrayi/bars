import BarsCore
import Commander
import Foundation

struct TokenAccountCLISelection {
    let label: String?
    let index: Int?
    let allAccounts: Bool

    var usesOverride: Bool {
        self.label != nil || self.index != nil || self.allAccounts
    }

    func providerSelectionError(_ providers: [UsageProvider]) -> String? {
        guard self.usesOverride else { return nil }
        guard providers.count == 1 else { return "account selection requires a single provider." }
        let provider = providers[0]
        guard TokenAccountSupportCatalog.support(for: provider) != nil else {
            return "\(provider.rawValue) does not support token accounts."
        }
        return nil
    }
}

enum TokenAccountCLIResolutionScope {
    case configuredAccounts
    case ambientAccount
}

enum TokenAccountCLIError: LocalizedError {
    case noAccounts(UsageProvider)
    case accountNotFound(UsageProvider, String)
    case indexOutOfRange(UsageProvider, Int, Int)

    var errorDescription: String? {
        switch self {
        case let .noAccounts(provider):
            "No token accounts configured for \(provider.rawValue)."
        case let .accountNotFound(provider, label):
            "No token account labeled '\(label)' for \(provider.rawValue)."
        case let .indexOutOfRange(provider, index, count):
            "Token account index \(index) out of range for \(provider.rawValue) (1-\(count))."
        }
    }
}

struct TokenAccountCLIContext {
    let selection: TokenAccountCLISelection
    let config: BarsConfig
    let accountsByProvider: [UsageProvider: ProviderTokenAccountData]
    @ProcessEnvironment private(set) var baseEnvironment: [String: String]
    private let tokenWriteback: TokenAccountCLIWriteback

    init(
        selection: TokenAccountCLISelection,
        config: BarsConfig,
        verbose _: Bool,
        resolutionScope: TokenAccountCLIResolutionScope = .configuredAccounts,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        configStore: BarsConfigStore = BarsConfigStore()) throws
    {
        self.selection = selection
        self.config = config
        self.baseEnvironment = baseEnvironment
        self.tokenWriteback = TokenAccountCLIWriteback(store: configStore)
        self.accountsByProvider = switch resolutionScope {
        case .configuredAccounts:
            Dictionary(uniqueKeysWithValues: config.providers.compactMap { provider in
                guard let firstPartyProvider = provider.id.firstPartyProvider,
                      let accounts = provider.tokenAccounts
                else { return nil }
                return (firstPartyProvider, accounts)
            })
        case .ambientAccount:
            [:]
        }
    }

    func resolvedAccounts(
        for provider: UsageProvider, sourceMode: ProviderSourceMode? = nil) throws -> [ProviderTokenAccount]
    {
        guard let support = TokenAccountSupportCatalog.support(for: provider) else { return [] }
        let effectiveSourceMode = sourceMode ?? self.preferredSourceMode(for: provider)
        if !self.selection.usesOverride,
           support.passiveSourceModes.contains(effectiveSourceMode)
        {
            return []
        }
        guard let data = self.accountsByProvider[provider], !data.accounts.isEmpty else {
            if self.selection.usesOverride {
                throw TokenAccountCLIError.noAccounts(provider)
            }
            return []
        }

        if self.selection.allAccounts {
            return data.accounts
        }

        if let label = self.selection.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            let normalized = label.lowercased()
            if let match = data.accounts.first(where: { $0.label.lowercased() == normalized }) {
                return [match]
            }
            throw TokenAccountCLIError.accountNotFound(provider, label)
        }

        if let index = self.selection.index {
            guard index >= 0, index < data.accounts.count else {
                throw TokenAccountCLIError.indexOutOfRange(provider, index + 1, data.accounts.count)
            }
            return [data.accounts[index]]
        }

        let clamped = data.clampedActiveIndex()
        return [data.accounts[clamped]]
    }

    func settingsSnapshot(
        for provider: UsageProvider,
        account: ProviderTokenAccount?) -> ProviderSettingsSnapshot?
    {
        let config = self.providerConfig(for: provider)
        guard let contribution = ProviderDescriptorRegistry.descriptor(for: provider)
            .settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(config: config, account: account))
        else { return nil }
        return ProviderSettingsSnapshot(contributions: [contribution])
    }

    func environment(
        base: [String: String],
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> [String: String]
    {
        let providerConfig = self.providerConfig(for: provider)
        return ProviderEnvironmentResolver.resolve(
            base: base,
            provider: provider,
            config: providerConfig,
            selectedAccount: account)
    }

    func tokenUpdater(for account: ProviderTokenAccount?) -> ProviderFetchContext.TokenAccountTokenUpdater? {
        guard let account else { return nil }
        let writeback = self.tokenWriteback
        return { provider, accountID, token in
            guard accountID == account.id else { return }
            await writeback.update(provider: provider, account: account, token: token)
        }
    }

    func manualTokenUpdater() -> ProviderFetchContext.ProviderManualTokenUpdater {
        let writeback = self.tokenWriteback
        return { provider, token in
            await writeback.updateManual(provider: provider, token: token)
        }
    }

    @discardableResult
    static func updateStoredTokenAccount(
        store: BarsConfigStore,
        provider: UsageProvider,
        accountID: UUID,
        expectedToken: String,
        token: String) throws -> Bool
    {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var didUpdate = false
        try store.updateIfAvailable { config in
            guard var providerConfig = config.providerConfig(for: provider.instanceID),
                  let data = providerConfig.tokenAccounts,
                  let index = data.accounts.firstIndex(where: { $0.id == accountID })
            else {
                return false
            }

            let existing = data.accounts[index]
            guard existing.token == expectedToken else {
                BarsLog.logger(LogCategories.tokenAccounts).warning(
                    "Skipped token account writeback: the stored credential changed during the fetch",
                    metadata: ["provider": provider.rawValue])
                return false
            }
            var accounts = data.accounts
            accounts[index] = ProviderTokenAccount(
                id: existing.id,
                label: existing.label,
                token: trimmed,
                addedAt: existing.addedAt,
                lastUsed: existing.lastUsed,
                externalIdentifier: existing.externalIdentifier,
                usageScope: existing.usageScope,
                organizationID: existing.organizationID,
                workspaceID: existing.workspaceID,
                claudeConfigDirectory: existing.claudeConfigDirectory,
                seatCreditEntitlement: existing.seatCreditEntitlement,
                modelRateLimits: existing.modelRateLimits)
            providerConfig.tokenAccounts = ProviderTokenAccountData(
                version: data.version,
                accounts: accounts,
                activeIndex: data.clampedActiveIndex())
            config.setProviderConfig(providerConfig)
            didUpdate = true
            return true
        }
        return didUpdate
    }

    func effectiveSourceMode(
        base: ProviderSourceMode,
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> ProviderSourceMode
    {
        let config = self.providerConfig(for: provider)
        return ProviderDescriptorRegistry.descriptor(for: provider).credentials?
            .selectedAccountSourceMode(base: base, account: account, config: config) ?? base
    }

    func preferredSourceMode(for provider: UsageProvider) -> ProviderSourceMode {
        let config = self.providerConfig(for: provider)
        return config?.source ?? .auto
    }

    private func providerConfig(for provider: UsageProvider) -> ProviderConfig? {
        self.config.providerConfig(for: provider.instanceID)
    }
}

/// One command shares a writer across providers, while external config edits still win.
private actor TokenAccountCLIWriteback {
    private let store: BarsConfigStore
    private var expectedTokens: [UsageProvider: [UUID: String]] = [:]

    init(store: BarsConfigStore) {
        self.store = store
    }

    func updateManual(provider: UsageProvider, token: String) {
        try? ProviderDescriptorRegistry.descriptor(for: provider).credentials?.persistManualToken(token)
    }

    func update(provider: UsageProvider, account: ProviderTokenAccount, token: String) {
        if (try? TokenAccountCLIContext.updateStoredTokenAccount(
            store: self.store,
            provider: provider,
            accountID: account.id,
            expectedToken: self.expectedTokens[provider]?[account.id] ?? account.token,
            token: token)) == true
        {
            self.expectedTokens[provider, default: [:]][account.id] = token
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
