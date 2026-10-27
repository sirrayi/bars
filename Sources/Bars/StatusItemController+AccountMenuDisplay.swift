import AppKit
import BarsCore

enum ClaudeSwapMenuPrecedence {
    static func prefersClaudeSwap(
        provider: UsageProvider,
        accountCount: Int,
        showSingleAccount: Bool) -> Bool
    {
        // Provider-specific by design: claude-swap subprocess discovery owns Claude account presentation.
        provider == .claude && ClaudeSwapAccountProjection.shouldPresentAccounts(
            accountCount: accountCount,
            showSingleAccount: showSingleAccount)
    }
}

extension StatusItemController {
    func tokenAccountMenuDisplay(for provider: UsageProvider) -> TokenAccountMenuDisplay? {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return nil }
        // Retained Cursor manual accounts are dormant while Automatic browser discovery owns the live snapshot.
        guard self.settings.effectiveSelectedTokenAccount(for: provider) != nil else { return nil }
        // Eligible claude-swap rows are the selected Claude account source, so do not mix them
        // with token-account cards or the segmented token-account switcher.
        if ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: provider,
            accountCount: self.store.claudeSwapAccountSnapshots.count,
            showSingleAccount: self.settings.claudeSwapShowSingleAccount)
        {
            return nil
        }
        let accounts = self.settings.tokenAccounts(for: provider)
        guard accounts.count > 1 else { return nil }
        let activeIndex = self.settings.tokenAccountsData(for: provider)?.clampedActiveIndex() ?? 0
        let showAll = self.settings.multiAccountMenuLayout == .stacked
        let displayAccounts = showAll
            ? self.store.limitedTokenAccounts(accounts, selected: self.settings.selectedTokenAccount(for: provider))
            : accounts
        let snapshots = showAll
            ? self.tokenAccountSnapshots(for: provider, matching: displayAccounts)
            : []
        return TokenAccountMenuDisplay(
            provider: provider,
            accounts: displayAccounts,
            snapshots: snapshots,
            activeIndex: activeIndex,
            layout: showAll ? .stacked : .segmented)
    }

    private func tokenAccountSnapshots(
        for provider: UsageProvider,
        matching accounts: [ProviderTokenAccount]) -> [TokenAccountUsageSnapshot]
    {
        var snapshotsByID: [UUID: TokenAccountUsageSnapshot] = [:]
        for snapshot in self.store.validTokenAccountSnapshots(provider: provider, accounts: accounts) {
            snapshotsByID[snapshot.account.id] = snapshot
        }
        return accounts.compactMap { snapshotsByID[$0.id] }
    }
}
