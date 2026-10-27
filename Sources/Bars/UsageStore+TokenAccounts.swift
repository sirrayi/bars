import BarsCore
import Foundation

extension UsageStore {
    func activateCachedTokenAccountSnapshot(provider: UsageProvider, accountID: UUID) {
        guard self.settings.effectiveSelectedTokenAccount(for: provider)?.id == accountID else { return }
        self.invalidateGenericWidgetUsage(for: provider)
        self.tokenAccountLiveStateProviders.insert(provider.instanceID)
        guard let account = self.uniqueTokenAccount(provider: provider, accountID: accountID),
              let cached = self.accountSnapshots[provider.instanceID]?.first(where: {
                  $0.account.id == accountID
                      && $0.cacheKey
                      == self.tokenAccountSnapshotCacheKey(
                          provider: provider,
                          account: account)
              })
        else {
            self.accountSnapshots[provider.instanceID]?.removeAll { $0.account.id == accountID }
            self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
            // Never show the previous account's usage under the newly selected account. Segmented layouts only
            // fetch the active account, so an uncached selection must render as refreshing until its fetch completes.
            self.clearTokenAccountLiveSnapshot(provider: provider)
            return
        }

        self.knownLimitsAvailabilityByProvider[provider.instanceID] = .resolve(
            provider: provider,
            snapshot: cached.snapshot,
            lastErrorDescription: cached.error)

        if let snapshot = cached.snapshot {
            self.snapshots[provider.instanceID] = snapshot
            self.lastKnownResetSnapshots[provider.instanceID] = snapshot
            self.installProviderDerivedTokenSnapshot(from: snapshot, for: provider)
        } else {
            self.snapshots.removeValue(forKey: provider.instanceID)
            self.lastKnownResetSnapshots.removeValue(forKey: provider.instanceID)
            self.resetProviderDerivedTokenSnapshot(for: provider)
        }
        self.errors[provider.instanceID] = cached.error
        if let sourceLabel = cached.sourceLabel {
            self.lastSourceLabels[provider.instanceID] = sourceLabel
        } else {
            self.lastSourceLabels.removeValue(forKey: provider.instanceID)
        }
    }

    func cacheTokenAccountSnapshot(
        provider: UsageProvider,
        account: ProviderTokenAccount,
        snapshot: UsageSnapshot,
        sourceLabel: String?)
    {
        let support = TokenAccountSupportCatalog.support(for: provider)
        let cookieSource = self.settings.providerConfig(for: provider)?.cookieSource ?? .auto
        guard support?.selectedAccountRequiresManualCookieSource != true || cookieSource != .auto else {
            return
        }
        let cached = TokenAccountUsageSnapshot(
            account: account,
            snapshot: snapshot,
            error: nil,
            sourceLabel: sourceLabel,
            cacheKey: self.tokenAccountSnapshotCacheKey(provider: provider, account: account))
        var snapshots = self.accountSnapshots[provider.instanceID] ?? []
        if let index = snapshots.firstIndex(where: { $0.account.id == account.id }) {
            snapshots[index] = cached
        } else {
            snapshots.append(cached)
        }
        self.accountSnapshots[provider.instanceID] = snapshots
    }

    func pruneTokenAccountSnapshots(provider: UsageProvider, accounts: [ProviderTokenAccount]) {
        let retained = self.validTokenAccountSnapshots(provider: provider, accounts: accounts)
        if retained.isEmpty {
            self.accountSnapshots.removeValue(forKey: provider.instanceID)
        } else {
            self.accountSnapshots[provider.instanceID] = retained
        }
    }

    func reconcileSelectedTokenAccountSnapshotBeforeRefresh(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount])
    {
        self.pruneTokenAccountSnapshots(provider: provider, accounts: accounts)
        guard let selectedAccount = self.settings.effectiveSelectedTokenAccount(for: provider) else {
            if self.tokenAccountLiveStateProviders.remove(provider.instanceID) != nil {
                self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
                self.clearTokenAccountLiveSnapshot(provider: provider)
            }
            return
        }
        // A Settings edit can invalidate the selected credential or endpoint before its replacement refresh
        // completes. Reconcile the live card now so a failed/cancelled fetch cannot retain old-account data.
        self.activateCachedTokenAccountSnapshot(provider: provider, accountID: selectedAccount.id)
    }

    private func clearTokenAccountLiveSnapshot(provider: UsageProvider) {
        self.invalidateGenericWidgetUsage(for: provider)
        self.snapshots.removeValue(forKey: provider.instanceID)
        self.resetProviderDerivedTokenSnapshot(for: provider)
        self.errors.removeValue(forKey: provider.instanceID)
        self.lastSourceLabels.removeValue(forKey: provider.instanceID)
        self.lastKnownResetSnapshots.removeValue(forKey: provider.instanceID)
    }

    func validTokenAccountSnapshots(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount]) -> [TokenAccountUsageSnapshot]
    {
        let accountsByID = Dictionary(grouping: accounts, by: \.id).compactMapValues { matches in
            matches.count == 1 ? matches[0] : nil
        }
        return (self.accountSnapshots[provider.instanceID] ?? []).filter { cached in
            guard let account = accountsByID[cached.account.id] else { return false }
            return cached.cacheKey == self.tokenAccountSnapshotCacheKey(provider: provider, account: account)
        }
    }

    func uniqueTokenAccount(provider: UsageProvider, accountID: UUID) -> ProviderTokenAccount? {
        let matches = self.settings.tokenAccounts(for: provider).filter { $0.id == accountID }
        return matches.count == 1 ? matches[0] : nil
    }
}

extension UsageStore {
    func refreshTokenAccounts(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount],
        generation: UInt64? = nil,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async
    {
        guard let selectedAccount = self.settings.effectiveSelectedTokenAccount(for: provider) else {
            self.reconcileSelectedTokenAccountSnapshotBeforeRefresh(provider: provider, accounts: accounts)
            return
        }
        let limitedAccounts = self.limitedTokenAccounts(accounts, selected: selectedAccount)

        // Capture the prior per-account snapshot state so we can preserve last-good
        // data when an in-flight refresh is cancelled (e.g. menu tab switches). Without
        // this, cancellation produces empty/error snapshots and the menu briefly shows
        // misleading cards for accounts that previously had valid data.
        self.pruneTokenAccountSnapshots(provider: provider, accounts: accounts)
        self.activateCachedTokenAccountSnapshot(provider: provider, accountID: selectedAccount.id)
        let priorSnapshots = self.accountSnapshots[provider.instanceID] ?? []
        let priorByAccountID = Dictionary(
            uniqueKeysWithValues: priorSnapshots.map { ($0.account.id, $0) })

        var snapshots: [TokenAccountUsageSnapshot] = []
        var historySamples: [(account: ProviderTokenAccount, snapshot: UsageSnapshot)] = []
        var selectedOutcome: ProviderFetchOutcome?
        var resolvedSelectedAccount: ProviderTokenAccount?
        var selectedSnapshot: UsageSnapshot?
        var selectedAccountSnapshot: TokenAccountUsageSnapshot?
        var sawAnyNonCancellationOutcome = false

        let results = await self.fetchTokenAccountOutcomes(
            provider: provider, accounts: limitedAccounts, sleep: sleep)
        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
        for result in results {
            guard let account = self.uniqueTokenAccount(provider: provider, accountID: result.account.id)
            else { continue }
            let outcome = result.outcome
            let isCancellation: Bool = if case let .failure(error) = outcome.result {
                Self.shouldSuppressProviderCancellation(error, priorSnapshot: priorByAccountID[account.id]?.snapshot)
            } else {
                false
            }
            if !isCancellation {
                sawAnyNonCancellationOutcome = true
            }
            let resolved = self.resolveAccountOutcome(
                outcome,
                provider: provider,
                account: account,
                priorSnapshot: priorByAccountID[account.id])
            if let snapshot = resolved.snapshot {
                snapshots.append(snapshot)
            }
            if let usage = resolved.freshUsage {
                historySamples.append((account: account, snapshot: usage))
            }
            if account.id == selectedAccount.id {
                selectedOutcome = outcome
                resolvedSelectedAccount = account
                selectedSnapshot = resolved.usage
                selectedAccountSnapshot = resolved.snapshot
            }
        }

        // If every fetch was cancelled (e.g. the user closed/reopened the menu mid-flight)
        // and we have no usable snapshots, leave the prior per-account state alone.
        // Wiping it would produce a menu of useless "cancelled" placeholders.
        let shouldPreservePriorState =
            !sawAnyNonCancellationOutcome && snapshots.allSatisfy { $0.snapshot == nil }
        if !shouldPreservePriorState {
            self.accountSnapshots[provider.instanceID] = snapshots
        }

        if let selectedOutcome, let resolvedSelectedAccount {
            await self.applySelectedOutcome(
                selectedOutcome,
                provider: provider,
                account: resolvedSelectedAccount,
                fallbackSnapshot: selectedSnapshot,
                fallbackAccountSnapshot: selectedAccountSnapshot,
                generation: generation)
        }

        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
        await self.recordFetchedTokenAccountPlanUtilizationHistory(
            provider: provider,
            samples: historySamples,
            selectedAccount: selectedAccount)
    }

    func limitedTokenAccounts(
        _ accounts: [ProviderTokenAccount],
        selected: ProviderTokenAccount?) -> [ProviderTokenAccount]
    {
        let limit = Self.tokenAccountMenuSnapshotLimit
        if accounts.count <= limit {
            return accounts
        }
        var limited = Array(accounts.prefix(limit))
        if let selected, !limited.contains(where: { $0.id == selected.id }) {
            limited.removeLast()
            limited.append(selected)
        }
        return limited
    }

    func fetchOutcome(
        provider: UsageProvider,
        override: TokenAccountOverride?) async -> ProviderFetchOutcome
    {
        let descriptor =
            self.providerSpecs[provider]?.descriptor
                ?? ProviderDescriptorRegistry
                .descriptor(for: provider)
        let context = self.makeFetchContext(provider: provider, override: override)
        return await descriptor.fetchOutcome(context: context)
    }

    private func fetchTokenAccountOutcomes(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount],
        sleep: (Duration) async throws -> Void) async -> [TokenAccountFetchResult]
    {
        let descriptor =
            self.providerSpecs[provider]?.descriptor
                ?? ProviderDescriptorRegistry
                .descriptor(for: provider)
        let requests:
            [(
                index: Int,
                account: ProviderTokenAccount,
                context: ProviderFetchContext)] =
            accounts.enumerated().map { index, account in
                let override = TokenAccountOverride(provider: provider, account: account)
                let context = self.makeFetchContext(provider: provider, override: override)
                return (index, account, context)
            }

        if let delay = TokenAccountSupportCatalog.support(for: provider)?
            .minimumDelayBetweenAccountRefreshes
        {
            var results: [TokenAccountFetchResult] = []
            results.reserveCapacity(requests.count)
            for request in requests {
                if !results.isEmpty {
                    do {
                        try await sleep(delay)
                    } catch {
                        for pending in requests.dropFirst(results.count) {
                            results.append(
                                TokenAccountFetchResult(
                                    index: pending.index,
                                    account: pending.account,
                                    outcome: ProviderFetchOutcome(
                                        result: .failure(CancellationError()),
                                        attempts: [])))
                        }
                        return results
                    }
                }
                let outcome = await descriptor.fetchOutcome(context: request.context)
                results.append(
                    TokenAccountFetchResult(
                        index: request.index,
                        account: request.account,
                        outcome: outcome))
            }
            return results
        }

        return await withTaskGroup(
            of: TokenAccountFetchResult.self,
            returning: [TokenAccountFetchResult].self)
        { group in
            for request in requests {
                group.addTask {
                    let outcome = await descriptor.fetchOutcome(context: request.context)
                    return TokenAccountFetchResult(
                        index: request.index,
                        account: request.account,
                        outcome: outcome)
                }
            }

            var results: [TokenAccountFetchResult] = []
            results.reserveCapacity(requests.count)
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    func makeFetchContext(
        provider: UsageProvider,
        override: TokenAccountOverride?,
        includeCredits: Bool = false,
        claudeOwnerCLIRecoveryOnly: Bool = false) -> ProviderFetchContext
    {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: provider,
            settings: self.settings,
            override: override)
        let sourceMode = ProviderRegistry.resolvedSourceMode(
            provider: provider,
            settings: self.settings,
            account: account)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(
            settings: self.settings,
            tokenOverride: override)
        let env = ProviderRegistry.makeEnvironment(
            base: self.environmentBase,
            provider: provider,
            settings: self.settings,
            tokenOverride: override)
        let contextProvider = provider
        let publicationGeneration = self.providerRefreshPublicationContexts[provider.instanceID]?
            .generation
        let contextConfigRevision = self.settings.providerConfigRevision(for: provider)
        let originalAccountToken = account?.token
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: includeCredits,
            includeOptionalUsage: ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
                provider: provider,
                settings: self.settings,
                override: override),
            includeAccountIdentity: self.settings.accountWidgetsEnabled && account != nil,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: self.settings.isVerboseLoggingEnabled,
            env: env,
            settings: snapshot,
            claudeFetcher: self.claudeFetcher,
            browserDetection: self.browserDetection,
            selectedTokenAccountID: account?.id,
            tokenAccountTokenUpdater: { [weak self] provider, accountID, token in
                await MainActor.run {
                    guard let self, provider == contextProvider,
                          self.settings.tokenAccounts(for: provider)
                              .first(where: { $0.id == accountID })?.token == originalAccountToken
                    else {
                        return
                    }
                    guard
                        self.providerConfigMutationIsCurrent(
                            provider: provider,
                            generation: publicationGeneration,
                            originalConfigRevision: contextConfigRevision)
                    else { return }
                    self.settings.updateTokenAccount(
                        provider: provider,
                        accountID: accountID,
                        token: token)
                    self.advanceProviderRefreshConfigRevision(
                        provider: provider,
                        generation: publicationGeneration)
                }
            },
            costUsageHistoryDays: self.settings.costUsageHistoryDays,
            claudeOwnerCLIRecoveryOnly: claudeOwnerCLIRecoveryOnly,
            persistsCLISessions: true,
            persistentCLISessionIdleWindow: ProviderRegistry.persistentCLISessionIdleWindow(
                refreshInterval: self.normalRefreshIntervalForHeuristics()),
            resolvedCLIVersion: self.version(for: provider))
    }

    func providerConfigMutationIsCurrent(
        provider: UsageProvider,
        generation: UInt64?,
        originalConfigRevision: UInt64) -> Bool
    {
        guard let generation else { return true }
        let currentConfigRevision = self.settings.providerConfigRevision(for: provider)
        guard let publication = self.providerRefreshPublicationContexts[provider.instanceID] else {
            return false
        }
        if publication.generation == generation {
            return publication.configRevision == currentConfigRevision
        }
        // A replacement waits for its predecessor before capturing fetch inputs. Let the predecessor persist an
        // authorized refresh token while its original config is unchanged; the replacement will then start from it.
        return originalConfigRevision == currentConfigRevision
    }

    func advanceProviderRefreshConfigRevision(provider: UsageProvider, generation: UInt64?) {
        guard let generation,
              var publication = self.providerRefreshPublicationContexts[provider.instanceID],
              publication.generation == generation
        else { return }
        publication.configRevision = self.settings.providerConfigRevision(for: provider)
        self.providerRefreshPublicationContexts[provider.instanceID] = publication
    }

    func sourceMode(for provider: UsageProvider) -> ProviderSourceMode {
        ProviderCatalog.implementation(for: provider)?
            .sourceMode(context: ProviderSourceModeContext(provider: provider, settings: self.settings))
            ?? .auto
    }

    private struct ResolvedAccountOutcome {
        let snapshot: TokenAccountUsageSnapshot?
        let usage: UsageSnapshot?
        let freshUsage: UsageSnapshot?
    }

    func tokenAccountErrorMessage(_ error: any Error) -> String? {
        // Owned browser cancellation is suppressed only after checking the actual prior balance owner.
        guard error is DeepSeekPlatformTransportError || !Self.errorIsCancellation(error) else { return nil }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    /// Per-account snapshot error text. Cancellation is handled before this path so
    /// transient menu refresh cancellation does not render as a user-facing error.
    func tokenAccountSnapshotErrorMessage(_ error: any Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Refresh failed" : message
    }

    func recordFetchedTokenAccountPlanUtilizationHistory(
        provider: UsageProvider,
        samples: [(account: ProviderTokenAccount, snapshot: UsageSnapshot)],
        selectedAccount: ProviderTokenAccount?) async
    {
        for sample in samples where sample.account.id != selectedAccount?.id {
            await self.recordPlanUtilizationHistorySample(
                provider: provider,
                snapshot: sample.snapshot,
                account: sample.account,
                shouldUpdatePreferredAccountKey: false,
                shouldAdoptUnscopedHistory: false)
        }
    }

    private func resolveAccountOutcome(
        _ outcome: ProviderFetchOutcome,
        provider: UsageProvider,
        account: ProviderTokenAccount,
        priorSnapshot: TokenAccountUsageSnapshot? = nil) -> ResolvedAccountOutcome
    {
        self.handleCredentialOutcome(
            provider: provider,
            account: Self.warningTokenAccountDiscriminator(account) ?? "default",
            result: outcome.result)
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            let current = scoped
            let labeled = current.withAccountLabel(account.label, for: provider)
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: labeled,
                error: nil,
                sourceLabel: result.sourceLabel,
                cacheKey: self.tokenAccountSnapshotCacheKey(provider: provider, account: account))
            return ResolvedAccountOutcome(snapshot: snapshot, usage: labeled, freshUsage: labeled)
        case let .failure(error):
            let prior = self.matchingTokenAccountSnapshot(priorSnapshot, provider: provider, account: account)
            if Self.shouldSuppressProviderCancellation(error, priorSnapshot: prior?.snapshot) {
                return ResolvedAccountOutcome(snapshot: prior, usage: prior?.snapshot, freshUsage: nil)
            }
            let oauthLimited = Self.preservesClaudeOAuthSnapshot(error, provider: provider, snapshot: prior)
            let retained = oauthLimited || Self.shouldPreservePriorSnapshot(
                after: error,
                hadPriorData: prior != nil,
                priorSnapshot: prior?.snapshot)
                ? prior : nil
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: retained?.snapshot,
                error: oauthLimited ? nil : self.tokenAccountSnapshotErrorMessage(error),
                sourceLabel: retained?.sourceLabel,
                cacheKey: self.tokenAccountSnapshotCacheKey(provider: provider, account: account),
                fetchError: error)
            return ResolvedAccountOutcome(snapshot: snapshot, usage: retained?.snapshot, freshUsage: nil)
        }
    }

    private func matchingTokenAccountSnapshot(
        _ snapshot: TokenAccountUsageSnapshot?,
        provider: UsageProvider,
        account: ProviderTokenAccount) -> TokenAccountUsageSnapshot?
    {
        guard let snapshot, snapshot.account.id == account.id, snapshot.snapshot != nil,
              let current = self.uniqueTokenAccount(provider: provider, accountID: account.id),
              snapshot.cacheKey == self.tokenAccountSnapshotCacheKey(provider: provider, account: current)
        else { return nil }
        return snapshot
    }

    private static func preservesClaudeOAuthSnapshot(
        _ error: Error,
        provider: UsageProvider,
        snapshot: TokenAccountUsageSnapshot?) -> Bool
    {
        // Provider-specific by design: a matching Claude OAuth cache survives OAuth usage throttling.
        provider == .claude && snapshot?.sourceLabel == "oauth" && ClaudeUsageError.isClaudeOAuthUsageRateLimit(error)
    }

    private func publishSelectedAccountFailure(
        _ error: Error,
        provider: UsageProvider,
        preserving snapshot: UsageSnapshot?,
        sourceLabel: String?,
        hadPriorData: Bool)
    {
        guard let message = self.tokenAccountErrorMessage(error) else {
            self.errors[provider.instanceID] = nil
            return
        }
        if let snapshot {
            self.snapshots[provider.instanceID] = snapshot
            self.lastKnownResetSnapshots[provider.instanceID] = snapshot
            self.lastSourceLabels[provider.instanceID] = sourceLabel
            self.installProviderDerivedTokenSnapshot(from: snapshot, for: provider)
        }
        let shouldSurface = self.failureGates[provider.instanceID]?
            .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
        self.errors[provider.instanceID] = shouldSurface ? message : nil
        if shouldSurface, snapshot == nil {
            self.invalidateGenericWidgetUsage(for: provider)
            self.snapshots.removeValue(forKey: provider.instanceID)
            self.clearProviderDerivedTokenSnapshot(for: provider)
        }
    }

    func applySelectedOutcome(
        _ outcome: ProviderFetchOutcome,
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        fallbackSnapshot: UsageSnapshot?,
        fallbackAccountSnapshot: TokenAccountUsageSnapshot? = nil,
        generation: UInt64? = nil) async
    {
        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
        if case .failure = outcome.result, let account,
           self.settings.effectiveSelectedTokenAccount(for: provider)?.id != account.id
        {
            return
        }
        self.lastFetchAttempts[provider.instanceID] = outcome.attempts
        self.handleCredentialOutcome(
            provider: provider,
            account: Self.warningTokenAccountDiscriminator(account) ?? "default",
            result: outcome.result)
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            let current = scoped
            let labeled: UsageSnapshot =
                if let account {
                    current.withAccountLabel(account.label, for: provider)
                } else {
                    current
                }
            let profileStable =
                provider == .deepseek
                    ? labeled.preservingDeepSeekPlatformProfiles(
                        from: self.presentationSnapshot(for: .deepseek))
                    : labeled
            let backfilled = profileStable.backfillingResetTimes(
                from: self.lastKnownResetSnapshots[provider.instanceID])
            let warningAccountDiscriminator = Self.warningTokenAccountDiscriminator(account)
            self.handleQuotaWarningTransitions(
                provider: provider,
                snapshot: backfilled,
                accountDiscriminator: warningAccountDiscriminator)
            let sessionRestored = self.handleSessionQuotaTransition(
                provider: provider, snapshot: backfilled, accountDiscriminator: warningAccountDiscriminator)
            self.handlePredictivePaceWarningTransitions(
                provider: provider,
                snapshot: backfilled,
                accountDiscriminatorOverride: provider == .claude ? warningAccountDiscriminator : nil)
            self.lastKnownResetSnapshots[provider.instanceID] = backfilled
            self.snapshots[provider.instanceID] = backfilled
            self.widgetUsagePreservationBlockedProviders.remove(provider.instanceID)
            if provider == .deepseek {
                self.clearDeepSeekProfileTransition()
            }
            self.publishProviderDerivedTokenSnapshot(from: backfilled, for: provider)
            self.lastSourceLabels[provider.instanceID] = result.sourceLabel
            self.errors[provider.instanceID] = nil
            self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
            self.failureGates[provider.instanceID]?.recordSuccess()
            await self.recordPlanUtilizationHistorySample(
                provider: provider,
                snapshot: backfilled,
                account: account,
                sessionRestoredNotificationPending: sessionRestored)
            guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
            self.emitUsageUpdatedHook(
                provider: provider.instanceID,
                snapshot: backfilled,
                rateKey: warningAccountDiscriminator)
        case let .failure(error):
            let prior = account.flatMap {
                self.matchingTokenAccountSnapshot(fallbackAccountSnapshot, provider: provider, account: $0)
            }
            if error is DeepSeekPlatformTransportError,
               Self.shouldSuppressProviderCancellation(error, priorSnapshot: prior?.snapshot),
               let prior, let snapshot = prior.snapshot
            {
                self.snapshots[provider.instanceID] = snapshot
                self.lastKnownResetSnapshots[provider.instanceID] = snapshot
                self.lastSourceLabels[provider.instanceID] = prior.sourceLabel
                self.installProviderDerivedTokenSnapshot(from: snapshot, for: provider)
                self.errors[provider.instanceID] = nil
                self.markDeepSeekProfileTransitionUnavailable()
                return
            }
            if Self.preservesClaudeOAuthSnapshot(error, provider: provider, snapshot: prior),
               let prior, let fallback = prior.snapshot
            {
                self.snapshots[provider.instanceID] = fallback
                self.lastKnownResetSnapshots[provider.instanceID] = fallback
                self.lastSourceLabels[provider.instanceID] = "oauth"
                self.cacheTokenAccountSnapshot(
                    provider: provider,
                    account: prior.account,
                    snapshot: fallback,
                    sourceLabel: "oauth")
                self.errors[provider.instanceID] = nil
                self.failureGates[provider.instanceID]?.reset()
                return
            }
            self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
            if provider == .deepseek {
                self.markDeepSeekProfileTransitionUnavailable()
            }
            let retained = Self.shouldPreservePriorSnapshot(
                after: error,
                hadPriorData: prior != nil,
                priorSnapshot: prior?.snapshot)
                ? prior?.snapshot : nil
            self.publishSelectedAccountFailure(
                error,
                provider: provider,
                preserving: retained,
                sourceLabel: prior?.sourceLabel,
                hadPriorData: self.snapshots[provider.instanceID] != nil || fallbackSnapshot != nil)
        }
    }
}

extension UsageStore {
    func tokenAccountRefreshPreparation(for provider: UsageProvider)
        -> (accounts: [ProviderTokenAccount], removesAccountAuthority: Bool)
    {
        let accounts = self.tokenAccounts(for: provider)
        let removesAccountAuthority =
            self.tokenAccountLiveStateProviders.contains(provider.instanceID)
            && self.settings.effectiveSelectedTokenAccount(for: provider) == nil
        return (accounts, removesAccountAuthority)
    }
}
