import CodexBarCore
import CryptoKit
import Foundation

extension UsageStore {
    func widgetAccountOverflowCounts() -> [String: Int] {
        guard self.settings.accountWidgetsEnabled else { return [:] }
        var counts: [String: Int] = [:]
        for provider in self.enabledProviders().compactMap(\.firstPartyProvider).filter(Self.supportsWidgetUsage) {
            let count: Int
            // Match the account writer's source precedence without expanding its refresh or identity budget.
            // Provider-specific by design: Claude Swap owns its inventory when it supplies account snapshots.
            if provider == .claude, self.settings.claudeSwapEnabled, !self.claudeSwapAccountSnapshots.isEmpty {
                count = self.claudeSwapAccountSnapshots.count
            } else if self.settings.effectiveSelectedTokenAccount(for: provider) != nil {
                count = self.settings.tokenAccounts(for: provider).count
            } else {
                continue
            }
            let overflow = count - Self.tokenAccountMenuSnapshotLimit
            if overflow > 0 { counts[provider.rawValue] = overflow }
        }
        return counts
    }

    func makeWidgetAccountEntries(now: Date) -> [WidgetSnapshot.AccountEntry] {
        defer { self.widgetAccountSnapshotStore?.save(self.widgetVerifiedTokenSnapshots) }
        guard self.settings.accountWidgetsEnabled else {
            self.widgetVerifiedTokenSnapshots = [:]
            return []
        }
        let providers = self.enabledProviders().compactMap(\.firstPartyProvider).filter(Self.supportsWidgetUsage)
        self.widgetVerifiedTokenSnapshots = self.widgetVerifiedTokenSnapshots.filter { providers.contains($0.key) }
        return providers.flatMap { provider in
            self.widgetAccounts(for: provider, now: now)
        }
    }

    private func widgetAccounts(for provider: UsageProvider, now: Date) -> [WidgetSnapshot.AccountEntry] {
        // Provider-specific by design: Claude Swap owns its account polling and retained-owner guards.
        if provider == .claude, self.settings.claudeSwapEnabled,
           !self.claudeSwapAccountSnapshots.isEmpty
        {
            var accounts = Array(self.claudeSwapAccountSnapshots.prefix(Self.tokenAccountMenuSnapshotLimit))
            if let active = self.claudeSwapAccountSnapshots.first(where: \.isActive),
               !accounts.contains(where: { $0.id == active.id })
            {
                accounts.removeLast()
                accounts.append(active)
            }
            return accounts.compactMap { account in
                // Slots can be reused. Bind the pin to the same opaque ownership guard as retained usage,
                // without persisting the adapter's email, organization, or display label.
                guard let id = Self.claudeSwapWidgetOwnerKey(for: account) else { return nil }
                return self.widgetAccountEntry(
                    provider: provider,
                    id: id,
                    label: "Account \(account.id.opaqueID)",
                    snapshot: account.snapshot,
                    now: now)
            }
        }
        guard self.settings.effectiveSelectedTokenAccount(for: provider) != nil else {
            self.widgetVerifiedTokenSnapshots[provider] = nil
            return []
        }
        let accounts = self.settings.tokenAccounts(for: provider)
        let uniqueIDs = Set(Dictionary(grouping: accounts, by: \.id).filter { $0.value.count == 1 }.keys)
        let snapshots = self.validTokenAccountSnapshots(provider: provider, accounts: accounts)
        let previous = self.widgetVerifiedTokenSnapshots[provider] ?? [:]
        var verified: [UUID: WidgetVerifiedTokenSnapshot] = [:]
        let entries = self.limitedTokenAccounts(
            accounts, selected: self.settings.effectiveSelectedTokenAccount(for: provider))
            .enumerated().compactMap { index, account -> WidgetSnapshot.AccountEntry? in
                guard uniqueIDs.contains(account.id) else { return nil }
                let scope = self.widgetTokenCredentialScope(provider: provider, account: account)
                let matches = snapshots.filter { $0.id == account.id }
                guard matches.count <= 1 else { return nil }
                let current = matches.first
                let record: WidgetVerifiedTokenSnapshot
                if let snapshot = current?.snapshot,
                   let id = Self.widgetTokenAccountID(provider: provider, account: account, snapshot: snapshot)
                {
                    record = WidgetVerifiedTokenSnapshot(
                        credentialScope: scope,
                        widgetID: id,
                        usage: self.widgetAccountQuota(provider: provider, snapshot: snapshot, now: now))
                } else if let prior = previous[account.id], prior.credentialScope == scope,
                          prior.usage.provider == provider.instanceID,
                          Self.canRetainWidgetSnapshot(after: current)
                {
                    // Keep the last verified quota at its original age only while the exact credential scope remains.
                    record = prior
                } else {
                    return nil
                }
                verified[account.id] = record
                return WidgetSnapshot.AccountEntry(
                    id: record.widgetID,
                    provider: provider.instanceID,
                    label: self.settings.hidePersonalInfo ? "Account \(index + 1)" : account.displayName,
                    usage: record.usage)
            }
        self.widgetVerifiedTokenSnapshots[provider] = verified
        return entries
    }

    private static func canRetainWidgetSnapshot(
        after current: TokenAccountUsageSnapshot?) -> Bool
    {
        guard let current, current.error != nil else { return true }
        guard let error = current.fetchError else { return false }
        return Self.shouldPreservePriorSnapshot(after: error, hadPriorData: true)
    }

    static func widgetTokenAccountID(
        provider: UsageProvider,
        account: ProviderTokenAccount,
        snapshot: UsageSnapshot) -> String?
    {
        // withAccountLabel may fill a missing email with a user label. Only a returned account ID proves ownership.
        let identity = snapshot.identity(for: provider.instanceID)
        guard let owner = (identity?.widgetAccountOwnerID ?? identity?.accountID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !owner.isEmpty,
            let data = try? JSONEncoder().encode([
                "v1", provider.rawValue, account.id.uuidString.lowercased(), owner,
                account.sanitizedUsageScope ?? "", account.sanitizedOrganizationID ?? "",
                account.sanitizedWorkspaceID ?? "",
            ])
        else { return nil }
        return "\(provider.rawValue)/token:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func widgetTokenCredentialScope(provider: UsageProvider, account: ProviderTokenAccount) -> String {
        let scoped = ProviderTokenAccount(
            id: account.id,
            label: "",
            token: account.token,
            addedAt: 0,
            lastUsed: nil,
            externalIdentifier: account.externalIdentifier,
            usageScope: account.usageScope,
            organizationID: account.organizationID,
            workspaceID: account.workspaceID,
            seatCreditEntitlement: account.seatCreditEntitlement)
        return self.tokenAccountSnapshotCacheKey(provider: provider, account: scoped)
    }

    /// Saved widget pin and quota owner for an account-source slot. The ownership fingerprint hashes only
    /// slot and email, so each source needs its own namespace or claude-swap slot 1 and tcr slot 1 with the
    /// same email would share one pin. claude-swap keeps `claude/swap:` byte for byte: pins saved before tcr
    /// existed must still resolve.
    static func claudeSwapWidgetOwnerKey(for account: ProviderAccountUsageSnapshot) -> String? {
        guard let source = ClaudeSwapAccountSource(identitySource: account.id.source),
              let owner = ClaudeSwapRetainedUsageStore.ownershipFingerprint(for: account)
        else { return nil }
        let namespace = switch source {
        case .claudeSwap: "swap"
        case .tcr: "tcr"
        }
        return "claude/\(namespace):\(account.id.opaqueID):\(owner)"
    }

    static func widgetOpaqueAccountID(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func widgetAccountEntry(
        provider: UsageProvider,
        id: String,
        label: String,
        snapshot: UsageSnapshot?,
        now: Date) -> WidgetSnapshot.AccountEntry
    {
        let usage = snapshot.map { self.widgetAccountQuota(provider: provider, snapshot: $0, now: now) }
        return WidgetSnapshot.AccountEntry(id: id, provider: provider.instanceID, label: label, usage: usage)
    }

    private func widgetAccountQuota(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        now: Date) -> WidgetSnapshot.ProviderEntry
    {
        // Only account-owned quotas cross this boundary. Provider-level scans and dashboard extras have other owners.
        WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: snapshot.updatedAt,
            primary: snapshot.primary,
            secondary: snapshot.secondary,
            tertiary: snapshot.tertiary,
            usageRows: self.widgetUsageRows(provider: provider, snapshot: snapshot, now: now),
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
    }
}
