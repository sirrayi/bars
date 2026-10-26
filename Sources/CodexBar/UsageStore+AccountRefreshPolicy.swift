import CodexBarCore

extension UsageStore {
    static let tokenAccountMenuSnapshotLimit = 6

    func tokenAccounts(for provider: UsageProvider) -> [ProviderTokenAccount] {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return [] }
        return self.settings.tokenAccounts(for: provider)
    }

    func shouldFetchAllTokenAccounts(provider: UsageProvider, accounts: [ProviderTokenAccount]) -> Bool {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return false }
        guard self.settings.effectiveSelectedTokenAccount(for: provider) != nil else { return false }
        return self.settings.accountWidgetsEnabled && !accounts.isEmpty
            || self.settings.multiAccountMenuLayout == .stacked && accounts.count > 1
    }
}
