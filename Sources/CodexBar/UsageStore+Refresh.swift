import CodexBarCore
import Foundation

extension UsageStore {
    private struct ClaudeRefreshReconciliation {
        let disposition: ClaudeRefreshDisposition
        let oauthHistoryPersistentRefHash: String?
        let oauthActiveAccountObservation: ClaudeOAuthActiveAccountObservation
        var credentialFingerprint: String?
    }

    private enum ClaudeRefreshDisposition {
        case apply
        case retry
        case retryOwnerCLI
        case discard
    }

    private enum ProviderRefreshRetryMode {
        case ordinary
        case claudeOwnerCLIRecovery
    }

    private struct ClaudeRefreshReconciliationInput {
        let provider: UsageProvider
        let outcome: ProviderFetchOutcome
        @ProcessEnvironment private(set) var environment: [String: String]
        let dataSource: ClaudeUsageDataSource?
        let priorSourceLabel: String?
        let beforeFetch: ClaudeRefreshAuthState?
        let activeAccountIdentitySourceEligible: Bool
        let ownerCLIRecoveryPass: Bool
        let generation: UInt64
    }

    func refreshForSettingsChange() async {
        _ = await ProviderInteractionContext.$current.withValue(.background) {
            await self.runRefresh(
                startupConnectivityRetryAttempt: nil,
                coalesceProviderRefreshesOverride: false,
                waitForRefreshAvailability: true)
        }
    }

    private func providerRefreshSpec(_ provider: UsageProvider) async -> ProviderSpec? {
        if let override = self._test_providerRefreshOverride {
            await override(provider)
            return nil
        }
        return self.providerSpecs[provider]
    }

    func refreshProvider(
        _ provider: UsageProvider,
        allowDisabled: Bool = false,
        coalesceIfRefreshing: Bool = false) async
    {
        while coalesceIfRefreshing,
              let existingState = self.providerRefreshCoordinator.coalescingState(for: provider.instanceID)
        {
            switch await self.providerRefreshCoordinator.wait(for: provider.instanceID, state: existingState) {
            case .cancelled:
                return
            case .retryRequired:
                self.providerRefreshCoordinator.remove(existingState, for: provider.instanceID)
                continue
            case .completed:
                return
            }
        }

        let request = self.providerRefreshCoordinator.beginReplacingRequest(for: provider.instanceID)
        self.providerRefreshPublicationContexts[provider.instanceID] = ProviderRefreshPublicationContext(
            generation: request.generation,
            enablementRevision: self.settings.providerEnablementRevision(for: provider),
            configRevision: self.settings.providerConfigRevision(for: provider),
            tokenCostScopeSignature: Self.tokenCostRequiresProviderSnapshot(provider)
                ? self.tokenSnapshotScopeSignature(for: provider)
                : nil,
            allowDisabled: allowDisabled)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var snapshotUpdatedAtBeforeRefresh: Date?
            var didStartRefresh = false
            for predecessorState in request.predecessorStates {
                await predecessorState.waitForTaskCompletion()
            }
            if !Task.isCancelled,
               self.providerRefreshCoordinator.isCurrent(request.generation, for: provider.instanceID)
            {
                // A replacement can wait behind a predecessor while Settings changes. Capture
                // the publication inputs at actual fetch start so that queued work uses the new
                // configuration, while later changes still reject its suspended result.
                self.providerRefreshPublicationContexts[provider.instanceID] = ProviderRefreshPublicationContext(
                    generation: request.generation,
                    enablementRevision: self.settings.providerEnablementRevision(for: provider),
                    configRevision: self.settings.providerConfigRevision(for: provider),
                    tokenCostScopeSignature: Self.tokenCostRequiresProviderSnapshot(provider)
                        ? self.tokenSnapshotScopeSignature(for: provider)
                        : nil,
                    allowDisabled: allowDisabled)
                snapshotUpdatedAtBeforeRefresh = self.snapshot(for: provider.instanceID)?.updatedAt
                didStartRefresh = true
                await ProviderRefreshRequestContext.withNewRequest {
                    await self.refreshProviderTracked(
                        provider,
                        allowDisabled: allowDisabled,
                        generation: request.generation)
                }
            }
            let publishedNewSnapshot = didStartRefresh &&
                self.snapshot(for: provider.instanceID)?.updatedAt != snapshotUpdatedAtBeforeRefresh
            let retryRequired = !publishedNewSnapshot &&
                (Task.isCancelled || !self.isCurrentProviderRefreshGeneration(
                    provider,
                    generation: request.generation))
            self.providerRefreshCoordinator.complete(
                request.state,
                for: provider.instanceID,
                retryRequired: retryRequired)
        }
        request.state.install(task: task)
        _ = await self.providerRefreshCoordinator.wait(for: provider.instanceID, state: request.state)
    }

    func isCurrentProviderRefreshGeneration(_ provider: UsageProvider, generation: UInt64?) -> Bool {
        guard let generation else { return true }
        guard self.providerRefreshCoordinator.isCurrent(generation, for: provider.instanceID),
              let context = self.providerRefreshPublicationContexts[provider.instanceID],
              context.generation == generation
        else {
            return false
        }
        return context.enablementRevision == self.settings.providerEnablementRevision(for: provider) &&
            context.configRevision == self.settings.providerConfigRevision(for: provider) &&
            (context.tokenCostScopeSignature == nil ||
                context.tokenCostScopeSignature == self.tokenSnapshotScopeSignature(for: provider))
    }

    func currentProviderRefreshAllowsDisabledPublication(_ provider: UsageProvider) -> Bool {
        guard let context = self.providerRefreshPublicationContexts[provider.instanceID],
              context.allowDisabled,
              let state = self.providerRefreshCoordinator.coalescingState(for: provider.instanceID),
              state.generation == context.generation
        else {
            return false
        }
        return true
    }

    private func refreshProviderTracked(
        _ provider: UsageProvider,
        allowDisabled: Bool,
        generation: UInt64) async
    {
        if self.providerRefreshCoordinator.beginActivity(for: provider.instanceID) {
            self.refreshingProviders.insert(provider.instanceID)
        }
        defer {
            if self.providerRefreshCoordinator.endActivity(for: provider.instanceID) {
                self.refreshingProviders.remove(provider.instanceID)
            }
        }
        var retryMode: ProviderRefreshRetryMode?
        while !Task.isCancelled,
              self.isCurrentProviderRefreshGeneration(provider, generation: generation)
        {
            retryMode = await self.refreshProviderPass(
                provider,
                allowDisabled: allowDisabled,
                generation: generation,
                retryMode: retryMode)
            if retryMode == nil {
                break
            }
        }
    }

    /// Runs one provider fetch pass. A nonnil result keeps the retry inside the current coordinator request, so
    /// callers (including `runRefresh`) remain suspended until the account-stable replacement pass completes.
    private func refreshProviderPass(
        _ provider: UsageProvider,
        allowDisabled: Bool,
        generation: UInt64,
        retryMode: ProviderRefreshRetryMode?) async -> ProviderRefreshRetryMode?
    {
        guard let spec = await self.providerRefreshSpec(provider) else { return nil }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return nil }

        if !spec.isEnabled(), !allowDisabled {
            self.clearProviderRuntimeState(provider)
            return nil
        }

        if provider == .claude {
            self.scheduleClaudeSwapAccountRefresh(generation: generation)
        }

        let tokenAccountPreparation = self.tokenAccountRefreshPreparation(for: provider)
        if self.shouldFetchAllTokenAccounts(provider: provider, accounts: tokenAccountPreparation.accounts) {
            await self.refreshTokenAccounts(
                provider: provider,
                accounts: tokenAccountPreparation.accounts,
                generation: generation)
            return nil
        } else {
            _ = await MainActor.run {
                self.reconcileSelectedTokenAccountSnapshotBeforeRefresh(
                    provider: provider,
                    accounts: tokenAccountPreparation.accounts)
            }
        }

        let tokenAccount = self.settings.effectiveSelectedTokenAccount(for: provider)
        let fetchContext = self.makeFetchContext(
            provider: provider,
            override: nil,
            claudeOwnerCLIRecoveryOnly: retryMode == .claudeOwnerCLIRecovery)
        let claudeHasAdminAPIKey = ClaudeAdminAPISettingsReader.apiKey(environment: fetchContext.env) != nil
        let claudeActiveAccountIdentitySourceEligible = Self.shouldTrackClaudeActiveAccountIdentity(
            provider: provider,
            dataSource: fetchContext.settings?.claude?.usageDataSource,
            hasSelectedTokenAccount: tokenAccount != nil,
            hasAdminAPIKey: claudeHasAdminAPIKey)
        let priorClaudeSourceLabel = provider == .claude ? self.lastSourceLabels[.claude] : nil
        self.diagnostics[provider.instanceID] = nil
        let claudeAuthStateBeforeFetch = claudeActiveAccountIdentitySourceEligible
            ? await Self.captureClaudeRefreshAuthState(
                environment: fetchContext.env)
            : nil
        let priorTokenAccountSnapshot = self.tokenAccountSnapshot(provider: provider, account: tokenAccount)
        let descriptor = spec.descriptor
        let fetchOutcome: @Sendable () async -> ProviderFetchOutcome = {
            await descriptor.fetchOutcome(context: fetchContext)
        }
        // Keep provider fetch work off MainActor so slow keychain/process reads don't stall menu/UI responsiveness.
        let outcome: ProviderFetchOutcome = if let override = self._test_providerFetchOutcomeOverride {
            await override(provider)
        } else {
            await withTaskGroup(
                of: ProviderFetchOutcome.self,
                returning: ProviderFetchOutcome.self)
            { group in
                group.addTask(operation: fetchOutcome)
                return await group.next()!
            }
        }
        let claudeReconciliation = await self.reconcileClaudeRefreshAfterFetch(input: .init(
            provider: provider,
            outcome: outcome,
            environment: fetchContext.env,
            dataSource: fetchContext.settings?.claude?.usageDataSource,
            priorSourceLabel: priorClaudeSourceLabel,
            beforeFetch: claudeAuthStateBeforeFetch,
            activeAccountIdentitySourceEligible: claudeActiveAccountIdentitySourceEligible,
            ownerCLIRecoveryPass: retryMode == .claudeOwnerCLIRecovery,
            generation: generation))
        let outcomeContext = ProviderRefreshOutcomeContext(
            generation: generation,
            claudeUsesConsumerAutoPipeline: Self.isClaudeConsumerAutoPipeline(
                provider: provider,
                context: fetchContext,
                hasAdminAPIKey: claudeHasAdminAPIKey,
                hasTokenAccount: tokenAccount != nil,
                removedTokenAccountAuthority: tokenAccountPreparation.removesAccountAuthority),
            tokenAccount: tokenAccount,
            priorTokenAccountSnapshot: priorTokenAccountSnapshot,
            claudeOAuthHistoryPersistentRefHash: claudeReconciliation.oauthHistoryPersistentRefHash,
            claudeOAuthActiveAccountObservation: claudeReconciliation.oauthActiveAccountObservation,
            claudeCredentialFingerprint: claudeReconciliation.credentialFingerprint)
        return await self.completeProviderRefreshPass(
            provider: provider,
            outcome: outcome,
            reconciliation: claudeReconciliation,
            context: outcomeContext)
    }

    private func completeProviderRefreshPass(
        provider: UsageProvider,
        outcome: ProviderFetchOutcome,
        reconciliation: ClaudeRefreshReconciliation,
        context: ProviderRefreshOutcomeContext) async -> ProviderRefreshRetryMode?
    {
        switch reconciliation.disposition {
        case .retry:
            return .ordinary
        case .retryOwnerCLI:
            return .claudeOwnerCLIRecovery
        case .discard:
            return nil
        case .apply:
            break
        }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return nil }
        await self.applyProviderRefreshOutcome(provider: provider, outcome: outcome, context: context)
        return nil
    }

    private func reconcileClaudeRefreshAfterFetch(
        input: ClaudeRefreshReconciliationInput) async -> ClaudeRefreshReconciliation
    {
        guard input.provider == .claude else {
            return ClaudeRefreshReconciliation(
                disposition: .apply,
                oauthHistoryPersistentRefHash: nil,
                oauthActiveAccountObservation: .changed)
        }
        let historyAccountState = await Self.captureClaudeHistoryAccountState(environment: input.environment)
        guard self.isCurrentProviderRefreshGeneration(input.provider, generation: input.generation) else {
            return ClaudeRefreshReconciliation(
                disposition: .discard,
                oauthHistoryPersistentRefHash: nil,
                oauthActiveAccountObservation: .changed)
        }
        let fingerprintAfterFetch = historyAccountState.fingerprintToken
        let authChangedDuringFetch = Self.claudeAuthChangedDuringFetch(
            provider: input.provider,
            beforeFetch: input.beforeFetch,
            afterFetchFingerprintToken: fingerprintAfterFetch)
        let shouldTrackActiveAccount = Self.shouldReconcileClaudeActiveAccountIdentity(
            sourceEligible: input.activeAccountIdentitySourceEligible,
            dataSource: input.dataSource,
            outcome: input.outcome,
            priorSourceLabel: input.priorSourceLabel)
        await Self.invalidateClaudeCredentialsFileCacheIfNeeded(
            changedDuringFetch: shouldTrackActiveAccount && authChangedDuringFetch,
            environment: input.environment)
        guard self.isCurrentProviderRefreshGeneration(input.provider, generation: input.generation) else {
            return ClaudeRefreshReconciliation(
                disposition: .discard,
                oauthHistoryPersistentRefHash: nil,
                oauthActiveAccountObservation: .changed)
        }
        let activeAccountChangedDuringFetch = Self.claudeActiveAccountChangedDuringFetch(
            beforeFetch: input.beforeFetch?.activeAccountIdentity,
            afterFetch: historyAccountState.activeAccountIdentity,
            shouldTrack: shouldTrackActiveAccount,
            successfulCLIOutcome: Self.isSuccessfulClaudeCLIOutcome(input.outcome))
        let activeAccountReconciliation = self.reconcileClaudeActiveAccountIdentity(
            beforeFetch: input.beforeFetch?.activeAccountIdentity,
            afterFetch: historyAccountState.activeAccountIdentity,
            observedAccountUuids: [input.beforeFetch?.activeAccountUuid, historyAccountState.activeAccountUuid]
                .compactMap(\.self),
            shouldTrack: shouldTrackActiveAccount,
            environment: input.environment)
        let successfulOAuth = Self.isSuccessfulClaudeOAuthOutcome(input.outcome)
        let successfulOAuthCredentialOwner = Self.successfulClaudeOAuthCredentialOwner(input.outcome)
        let successfulOAuthHasIndependentAuthority = successfulOAuth && (
            successfulOAuthCredentialOwner == .environment || successfulOAuthCredentialOwner == .codexbar)
        let activeAccountChangedDuringFetchForOutcome =
            activeAccountChangedDuringFetch && !successfulOAuthHasIndependentAuthority
        let credentialsChanged = shouldTrackActiveAccount && !successfulOAuthHasIndependentAuthority && (
            Self.claudeCredentialsChanged(
                beforeFetch: input.beforeFetch,
                changedDuringFetch: authChangedDuringFetch) || activeAccountReconciliation.changed)
        let activeAccountMismatch = successfulOAuth && successfulOAuthCredentialOwner == .claudeCLI && (
            activeAccountChangedDuringFetch || activeAccountReconciliation.changedFromPersistedIdentity)
        let quarantinedCredentialsFile = if successfulOAuthCredentialOwner == .claudeCLI {
            await Self.isClaudeCredentialsFileQuarantinedForOAuth(environment: input.environment)
        } else {
            false
        }
        let oauthAccountMismatch = activeAccountMismatch || quarantinedCredentialsFile
        if oauthAccountMismatch {
            if activeAccountMismatch, successfulOAuthCredentialOwner == .claudeCLI {
                await Self.quarantineClaudeCredentialsFileForOAuth(environment: input.environment)
            }
            await Self.invalidateClaudeOAuthCache(environment: input.environment)
            guard self.isCurrentProviderRefreshGeneration(input.provider, generation: input.generation) else {
                return ClaudeRefreshReconciliation(
                    disposition: .discard,
                    oauthHistoryPersistentRefHash: nil,
                    oauthActiveAccountObservation: .changed)
            }
        }
        let ownerCLIRecoverySucceeded = !input.ownerCLIRecoveryPass || Self.isSuccessfulClaudeCLIOutcome(input.outcome)
        if !oauthAccountMismatch, !activeAccountChangedDuringFetchForOutcome, ownerCLIRecoverySucceeded {
            self.persistClaudeActiveAccountIdentity(
                activeAccountReconciliation.newestIdentity,
                environment: input.environment)
        }
        let sourceAuthorityChanged = Self.claudeSourceAuthorityChanged(
            priorSourceLabel: input.priorSourceLabel,
            dataSource: input.dataSource,
            outcome: input.outcome)
        let persistentRefHash = Self.stableClaudeKeychainPersistentRefHash(
            beforeFetch: input.beforeFetch,
            afterFetchFingerprintToken: fingerprintAfterFetch,
            afterFetchPersistentRefHash: historyAccountState.keychainPersistentRefHash,
            accountStateWasStable: historyAccountState.wasStable)
        let activeAccountObservation = Self.claudeOAuthActiveAccountObservation(
            beforeFetch: input.beforeFetch,
            afterFetch: historyAccountState)

        // Only the ambient CLI authority observes Claude's account/config files. Source-authority changes apply to
        // every Claude route, but retire only the live projection; configured token-account caches remain isolated.
        if credentialsChanged || activeAccountChangedDuringFetchForOutcome || sourceAuthorityChanged {
            self.clearClaudeCredentialDerivedStateForCredentialSwap()
        }
        let disposition: ClaudeRefreshDisposition = if oauthAccountMismatch {
            .retryOwnerCLI
        } else if activeAccountChangedDuringFetchForOutcome {
            .retry
        } else {
            .apply
        }
        return ClaudeRefreshReconciliation(
            disposition: disposition,
            oauthHistoryPersistentRefHash: persistentRefHash,
            oauthActiveAccountObservation: activeAccountObservation,
            credentialFingerprint: historyAccountState.wasStable &&
                input.beforeFetch?.fingerprintToken == fingerprintAfterFetch && fingerprintAfterFetch != "none"
                ? fingerprintAfterFetch : nil)
    }

    private func applyProviderRefreshOutcome(
        provider: UsageProvider,
        outcome: ProviderFetchOutcome,
        context: ProviderRefreshOutcomeContext) async
    {
        switch outcome.result {
        case let .success(result):
            await self.applyProviderRefreshSuccess(
                provider: provider,
                result: result,
                attempts: outcome.attempts,
                context: context)
        case let .failure(error):
            await self.applyProviderRefreshFailure(
                provider: provider,
                error: error,
                attempts: outcome.attempts,
                context: context)
        }
    }

    private func applyProviderRefreshSuccess(
        provider: UsageProvider,
        result: ProviderFetchResult,
        attempts: [ProviderFetchAttempt],
        context: ProviderRefreshOutcomeContext) async
    {
        let scoped = result.usage.scoped(to: provider)
        let currentTokenAccount = context.tokenAccount.flatMap { account in
            self.uniqueTokenAccount(provider: provider, accountID: account.id)
        }
        if context.tokenAccount != nil, currentTokenAccount == nil {
            return
        }
        let accountScoped = if let tokenAccount = currentTokenAccount {
            scoped.withAccountLabel(tokenAccount.label, for: provider)
        } else {
            scoped
        }
        let publication = await MainActor.run { () -> (snapshot: UsageSnapshot, sessionRestored: Bool)? in
            guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else {
                return nil
            }
            self.lastFetchAttempts[provider.instanceID] = attempts
            let resetBackfillSource = self.lastKnownResetSnapshots[provider.instanceID]
            // Resolve display-only allowances after any suspended request has completed.
            let allowanceCurrent = accountScoped
            let backfilled = self.preparePublishedSnapshot(
                allowanceCurrent, provider: provider, resetBackfillSource: resetBackfillSource)
            let notifications = self.handleProviderRefreshNotifications(
                provider: provider, result: result, snapshot: backfilled, context: context)
            self.lastKnownResetSnapshots[provider.instanceID] = backfilled
            self.snapshots[provider.instanceID] = backfilled
            self.widgetUsagePreservationBlockedProviders.remove(provider.instanceID)
            if provider == .deepseek {
                self.clearDeepSeekProfileTransition()
            }
            if let tokenSnapshot = self.tokenSnapshot(fromProviderSnapshot: backfilled, provider: provider) {
                self.publishTokenSnapshot(tokenSnapshot, for: provider)
                self.tokenErrors[provider.instanceID] = nil
                self.tokenFailureGates[provider.instanceID]?.recordSuccess()
            } else if Self.tokenCostRequiresProviderSnapshot(provider) {
                self.publishConfirmedEmptyTokenSnapshot(for: provider)
                self.tokenErrors[provider.instanceID] = nil
            }
            self.lastSourceLabels[provider.instanceID] = result.sourceLabel
            self.recordProviderFetchSuccessErrorState(provider: provider)
            self.diagnostics[provider.instanceID] = result.diagnostic
            if let tokenAccount = currentTokenAccount {
                self.cacheTokenAccountSnapshot(
                    provider: provider,
                    account: tokenAccount,
                    snapshot: backfilled,
                    sourceLabel: result.sourceLabel)
            }
            self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
            self.failureGates[provider.instanceID]?.recordSuccess()
            self.emitUsageUpdatedHook(
                provider: provider.instanceID,
                snapshot: backfilled,
                rateKey: notifications.account)
            return (backfilled, notifications.sessionRestored)
        }
        guard let publication else { return }
        let backfilled = publication.snapshot
        self.refreshClaudeVersionAfterUserInitiatedCLIFetch(provider: provider, strategyKind: result.strategyKind)
        let isClaudeOAuthSample = provider == .claude && result.strategyKind == .oauth
        let claudeOAuthPersistentRefHash: String? = if isClaudeOAuthSample,
                                                       result.claudeOAuthKeychainPersistentRefHash == context
                                                           .claudeOAuthHistoryPersistentRefHash
        {
            result.claudeOAuthKeychainPersistentRefHash
        } else {
            nil
        }
        await self.recordPlanUtilizationHistorySample(
            provider: provider,
            snapshot: backfilled,
            claudeOAuthPersistentRefHash: claudeOAuthPersistentRefHash,
            claudeOAuthHistoryOwnerIdentifier: isClaudeOAuthSample
                ? result.claudeOAuthHistoryOwnerIdentifier
                : nil,
            claudeOAuthKeychainCredentialMismatch: isClaudeOAuthSample
                && result.claudeOAuthKeychainCredentialMismatch,
            claudeOAuthKeychainCredentialAbsent: isClaudeOAuthSample
                && result.claudeOAuthKeychainCredentialAbsent,
            claudeOAuthKeychainCredentialUnavailable: isClaudeOAuthSample
                && (result.claudeOAuthKeychainCredentialUnavailable
                    || (result.claudeOAuthKeychainPersistentRefHash != nil
                        && claudeOAuthPersistentRefHash == nil)),
            claudeOAuthActiveAccountObservation: context.claudeOAuthActiveAccountObservation,
            isClaudeOAuthSample: isClaudeOAuthSample,
            sessionRestoredNotificationPending: publication.sessionRestored)
        guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return }
        if let runtime = self.providerRuntimes[provider.instanceID] {
            let runtimeContext = ProviderRuntimeContext(
                provider: provider, settings: self.settings, store: self)
            runtime.providerDidRefresh(context: runtimeContext, provider: provider)
        }
    }

    private func applyProviderRefreshFailure(
        provider: UsageProvider,
        error: Error,
        attempts: [ProviderFetchAttempt],
        context: ProviderRefreshOutcomeContext) async
    {
        // Credential-change cleanup already ran above; cancellation is now safe to suppress.
        if Self.shouldSuppressProviderCancellation(error, priorSnapshot: self.snapshots[provider.instanceID]) {
            if provider == .deepseek,
               self.isCurrentProviderRefreshGeneration(provider, generation: context.generation)
            {
                self.markDeepSeekProfileTransitionUnavailable()
            }
            return
        }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return }
        if provider == .deepseek {
            self.markDeepSeekProfileTransitionUnavailable()
        }
        self.handleCredentialOutcome(
            provider: provider,
            account: self.credentialAccount(provider: provider, context: context),
            result: .failure(error))
        self.lastFetchAttempts[provider.instanceID] = attempts
        if !Self.shouldPreservePriorSnapshot(
            after: error,
            hadPriorData: true,
            priorSnapshot: self.snapshots[provider.instanceID] ?? self.lastKnownResetSnapshots[provider.instanceID])
        {
            self.invalidateGenericWidgetUsage(for: provider)
        }
        self.recordStartupConnectivityRetryableFailure(error)
        await self.handleProviderFetchFailure(
            provider: provider,
            error: error,
            attempts: attempts,
            context: context)
    }

    private func preparePublishedSnapshot(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider,
        resetBackfillSource: UsageSnapshot?) -> UsageSnapshot
    {
        self.preservingDeepSeekProfileCatalog(in: snapshot, provider: provider)
            .backfillingResetTimesForProvider(provider, from: resetBackfillSource)
    }

    private func preservingDeepSeekProfileCatalog(
        in snapshot: UsageSnapshot,
        provider: UsageProvider) -> UsageSnapshot
    {
        guard provider == .deepseek else { return snapshot }
        return snapshot.preservingDeepSeekPlatformProfiles(from: self.presentationSnapshot(for: .deepseek))
    }

    private struct ClaudeRefreshAuthState {
        let fingerprintToken: String
        let credentialsFileChanged: Bool
        let keychainPersistentRefHash: String?
        let activeAccountUuid: String?
        let activeAccountIdentity: String?
        let accountStateWasStable: Bool
    }

    private struct ClaudeHistoryAccountState {
        let fingerprintToken: String
        let keychainPersistentRefHash: String?
        let activeAccountUuid: String?
        let activeAccountIdentity: String?
        let wasStable: Bool
    }

    private nonisolated static func claudeCredentialsChanged(
        beforeFetch: ClaudeRefreshAuthState?,
        changedDuringFetch: Bool) -> Bool
    {
        beforeFetch?.credentialsFileChanged == true ||
            changedDuringFetch
    }

    nonisolated static func shouldTrackClaudeActiveAccountIdentity(
        provider: UsageProvider,
        dataSource: ClaudeUsageDataSource?,
        hasSelectedTokenAccount: Bool,
        hasAdminAPIKey: Bool) -> Bool
    {
        guard provider == .claude, !hasSelectedTokenAccount else { return false }
        switch dataSource {
        case .cli:
            return true
        case .auto:
            return !hasAdminAPIKey
        case .oauth:
            // Explicit OAuth records sourced from the Claude file/cache require a stable account
            // observation before their unavailable-Keychain owner can enter history.
            return true
        case .api, .web, nil:
            return false
        }
    }

    private nonisolated static func shouldReconcileClaudeActiveAccountIdentity(
        sourceEligible: Bool,
        dataSource: ClaudeUsageDataSource?,
        outcome: ProviderFetchOutcome,
        priorSourceLabel: String?) -> Bool
    {
        guard sourceEligible else { return false }
        switch outcome.result {
        case let .success(result):
            // An OAuth result uses the owner-selected Claude profile just as the CLI route does.
            // A successful OAuth result must therefore reconcile a profile/account swap before
            // its reset snapshots can be published or backfilled.
            return result.strategyKind == .cli || result.strategyKind == .oauth
        case .failure:
            if dataSource == .cli {
                return true
            }
            let normalizedPriorSource = priorSourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Provider-specific by design: Claude's legacy CLI source label is part of refresh continuity.
            return normalizedPriorSource == "claude" || normalizedPriorSource == "cli"
        }
    }

    private nonisolated static func claudeActiveAccountChangedDuringFetch(
        beforeFetch: String?,
        afterFetch: String?,
        shouldTrack: Bool,
        successfulCLIOutcome: Bool) -> Bool
    {
        guard shouldTrack, let beforeFetch, beforeFetch != afterFetch else { return false }
        return afterFetch != nil || successfulCLIOutcome
    }

    private nonisolated static func isSuccessfulClaudeCLIOutcome(_ outcome: ProviderFetchOutcome) -> Bool {
        guard case let .success(result) = outcome.result else { return false }
        if case .cli = result.strategyKind {
            return true
        }
        return false
    }

    private nonisolated static func isSuccessfulClaudeOAuthOutcome(_ outcome: ProviderFetchOutcome) -> Bool {
        guard case let .success(result) = outcome.result else { return false }
        if case .oauth = result.strategyKind {
            return true
        }
        return false
    }

    private nonisolated static func successfulClaudeOAuthCredentialOwner(
        _ outcome: ProviderFetchOutcome) -> ClaudeOAuthCredentialOwner?
    {
        guard case let .success(result) = outcome.result,
              result.strategyKind == .oauth
        else { return nil }
        return result.claudeOAuthCredentialOwner
    }

    private enum ClaudeSourceAuthority: Equatable {
        case cli
        case web
        case api
        case oauth

        init?(sourceLabel: String?) {
            // Provider-specific by design: Claude CLI results historically used both provider and transport labels.
            switch sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "claude", "cli":
                self = .cli
            case "web":
                self = .web
            case "admin-api", "api":
                self = .api
            case "oauth":
                self = .oauth
            default:
                return nil
            }
        }

        init?(result: ProviderFetchResult) {
            switch result.strategyKind {
            case .cli:
                self = .cli
            case .web:
                self = .web
            case .apiToken:
                self = .api
            case .oauth:
                self = .oauth
            case .localProbe:
                self.init(sourceLabel: result.sourceLabel)
            }
        }

        init?(dataSource: ClaudeUsageDataSource?) {
            switch dataSource {
            case .cli:
                self = .cli
            case .web:
                self = .web
            case .api:
                self = .api
            case .oauth:
                self = .oauth
            case .auto, nil:
                return nil
            }
        }
    }

    private nonisolated static func claudeSourceAuthorityChanged(
        priorSourceLabel: String?,
        dataSource: ClaudeUsageDataSource?,
        outcome: ProviderFetchOutcome) -> Bool
    {
        guard let priorAuthority = ClaudeSourceAuthority(sourceLabel: priorSourceLabel) else { return false }
        let currentAuthority: ClaudeSourceAuthority? = switch outcome.result {
        case let .success(result):
            ClaudeSourceAuthority(result: result)
        case .failure:
            ClaudeSourceAuthority(dataSource: dataSource)
        }
        guard let currentAuthority else { return false }
        return priorAuthority != currentAuthority
    }

    private nonisolated static func claudeAuthChangedDuringFetch(
        provider: UsageProvider,
        beforeFetch: ClaudeRefreshAuthState?,
        afterFetchFingerprintToken: String?) -> Bool
    {
        // Provider-specific by design: Claude credential fingerprints invalidate results produced by an old OAuth key.
        provider == .claude && afterFetchFingerprintToken != beforeFetch?.fingerprintToken
    }

    private nonisolated static func captureClaudeRefreshAuthState(
        environment: [String: String]) async -> ClaudeRefreshAuthState
    {
        await withTaskGroup(of: ClaudeRefreshAuthState.self, returning: ClaudeRefreshAuthState.self) { group in
            group.addTask {
                let credentialsFileChanged = ClaudeOAuthCredentialsStore
                    .invalidateCacheIfCredentialsFileChanged(environment: environment)
                let fingerprintBefore = ClaudeOAuthCredentialsStore
                    .currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment: environment) ?? "none"
                let activeAccountUuid = Self.activeClaudeAccountUuid(environment: environment)
                let activeAccountIdentity = activeAccountUuid.map {
                    Self.claudeAccountIdentity($0, environment: environment)
                }
                let fingerprintAfter = ClaudeOAuthCredentialsStore
                    .currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment: environment) ?? "none"
                let accountStateWasStable = fingerprintBefore == fingerprintAfter
                return ClaudeRefreshAuthState(
                    fingerprintToken: fingerprintAfter,
                    credentialsFileChanged: credentialsFileChanged,
                    keychainPersistentRefHash: nil,
                    activeAccountUuid: activeAccountUuid,
                    activeAccountIdentity: activeAccountIdentity,
                    accountStateWasStable: accountStateWasStable)
            }
            return await group.next()!
        }
    }

    private nonisolated static func captureClaudeHistoryAccountState(
        environment: [String: String]) async -> ClaudeHistoryAccountState
    {
        await withTaskGroup(of: ClaudeHistoryAccountState.self, returning: ClaudeHistoryAccountState.self) { group in
            group.addTask {
                let fingerprintBefore = ClaudeOAuthCredentialsStore
                    .currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment: environment) ?? "none"
                let activeAccountUuid = Self.activeClaudeAccountUuid(environment: environment)
                let activeAccountIdentity = activeAccountUuid.map {
                    Self.claudeAccountIdentity($0, environment: environment)
                }
                let fingerprintAfter = ClaudeOAuthCredentialsStore
                    .currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment: environment) ?? "none"
                let wasStable = fingerprintBefore == fingerprintAfter
                return ClaudeHistoryAccountState(
                    fingerprintToken: fingerprintAfter,
                    keychainPersistentRefHash: nil,
                    activeAccountUuid: activeAccountUuid,
                    activeAccountIdentity: activeAccountIdentity,
                    wasStable: wasStable)
            }
            return await group.next()!
        }
    }

    private nonisolated static func claudeOAuthActiveAccountObservation(
        beforeFetch: ClaudeRefreshAuthState?,
        afterFetch: ClaudeHistoryAccountState?) -> ClaudeOAuthActiveAccountObservation
    {
        guard let beforeFetch,
              beforeFetch.accountStateWasStable,
              let afterFetch,
              afterFetch.wasStable,
              beforeFetch.activeAccountIdentity == afterFetch.activeAccountIdentity
        else {
            return .changed
        }
        return .stable(identity: afterFetch.activeAccountIdentity)
    }

    private nonisolated static func stableClaudeKeychainPersistentRefHash(
        beforeFetch: ClaudeRefreshAuthState?,
        afterFetchFingerprintToken: String?,
        afterFetchPersistentRefHash: String?,
        accountStateWasStable: Bool) -> String?
    {
        guard accountStateWasStable,
              let beforeFetch,
              beforeFetch.accountStateWasStable,
              beforeFetch.fingerprintToken == afterFetchFingerprintToken,
              let beforeFetchPersistentRefHash = beforeFetch.keychainPersistentRefHash,
              beforeFetchPersistentRefHash == afterFetchPersistentRefHash
        else {
            return nil
        }
        return beforeFetchPersistentRefHash
    }

    #if DEBUG
    nonisolated static func _stableClaudeKeychainPersistentRefHashForTesting(
        beforeFetchFingerprintToken: String,
        afterFetchFingerprintToken: String,
        beforeFetchPersistentRefHash: String?,
        afterFetchPersistentRefHash: String?) -> String?
    {
        self.stableClaudeKeychainPersistentRefHash(
            beforeFetch: ClaudeRefreshAuthState(
                fingerprintToken: beforeFetchFingerprintToken,
                credentialsFileChanged: false,
                keychainPersistentRefHash: beforeFetchPersistentRefHash,
                activeAccountUuid: nil,
                activeAccountIdentity: nil,
                accountStateWasStable: true),
            afterFetchFingerprintToken: afterFetchFingerprintToken,
            afterFetchPersistentRefHash: afterFetchPersistentRefHash,
            accountStateWasStable: true)
    }

    nonisolated static func _claudeOAuthActiveAccountObservationForTesting(
        identityBeforeFetch: String?,
        identityAfterFetch: String?,
        beforeFetchWasStable: Bool = true,
        afterFetchWasStable: Bool = true) -> ClaudeOAuthActiveAccountObservation
    {
        self.claudeOAuthActiveAccountObservation(
            beforeFetch: ClaudeRefreshAuthState(
                fingerprintToken: "before",
                credentialsFileChanged: false,
                keychainPersistentRefHash: "before-ref",
                activeAccountUuid: nil,
                activeAccountIdentity: identityBeforeFetch,
                accountStateWasStable: beforeFetchWasStable),
            afterFetch: ClaudeHistoryAccountState(
                fingerprintToken: "after",
                keychainPersistentRefHash: "after-ref",
                activeAccountUuid: nil,
                activeAccountIdentity: identityAfterFetch,
                wasStable: afterFetchWasStable))
    }
    #endif

    private nonisolated static func invalidateClaudeCredentialsFileCacheIfChanged(
        environment: [String: String]) async -> Bool
    {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged(environment: environment)
            }
            return await group.next()!
        }
    }

    private nonisolated static func invalidateClaudeCredentialsFileCacheIfNeeded(
        changedDuringFetch: Bool,
        environment: [String: String]) async
    {
        guard changedDuringFetch else { return }
        _ = await self.invalidateClaudeCredentialsFileCacheIfChanged(environment: environment)
    }

    private nonisolated static func invalidateClaudeOAuthCache(environment: [String: String]) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                ClaudeOAuthCredentialsStore.invalidateCache(environment: environment)
            }
            await group.waitForAll()
        }
    }

    private func clearClaudeCredentialDerivedStateForCredentialSwap() {
        // Provider-specific by design: retire Claude projections but preserve scoped warning episodes, including
        // unresolved accounts.
        self.widgetUsagePreservationBlockedProviders.insert(.claude)
        self.snapshots.removeValue(forKey: .claude)
        self.lastKnownResetSnapshots.removeValue(forKey: .claude)
        self.errors[.claude] = nil
        self.knownLimitsAvailabilityByProvider.removeValue(forKey: .claude)
        self.lastSourceLabels.removeValue(forKey: .claude)
        self.claudeHistoryFallbackEligible = false
        self.clearTokenSnapshot(for: .claude)
        self.tokenErrors[.claude] = nil
        self.failureGates[.claude]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        self.clearSessionQuotaTransitionState(provider: .claude)
        self.quotaWarningState = self.quotaWarningState.filter {
            $0.key.provider != .claude || $0.key.accountDiscriminator != nil
        }
        self.lastTokenFetchAt.removeValue(forKey: .claude)
    }

    private func handleProviderFetchFailure(
        provider: UsageProvider,
        error: Error,
        attempts: [ProviderFetchAttempt],
        context: ProviderRefreshOutcomeContext) async
    {
        guard !Task.isCancelled else { return }
        let shouldNotifyPermissionPrompt = Self.isPermissionPromptWaiting(error)
        await MainActor.run {
            guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return }
            self.diagnostics[provider.instanceID] = nil
            let restoredClaudeHistory = self.prepareClaudeHistoryFallback(
                provider: provider,
                usesConsumerAutoPipeline: context.claudeUsesConsumerAutoPipeline,
                accountStateWasStable: context.claudeOAuthActiveAccountObservation != .changed)
            if provider == .claude,
               ClaudeUsageError.isClaudeOAuthUsageRateLimit(error)
            {
                if let (account, cached) = self.validatedClaudeOAuthTokenAccountFallback(context: context),
                   let snapshot = cached.snapshot
                {
                    self.snapshots[provider.instanceID] = snapshot
                    self.lastKnownResetSnapshots[provider.instanceID] = snapshot
                    self.lastSourceLabels[provider.instanceID] = "oauth"
                    self.cacheTokenAccountSnapshot(
                        provider: provider,
                        account: account,
                        snapshot: snapshot,
                        sourceLabel: "oauth")
                    self.errors[provider.instanceID] = nil
                    self.failureGates[provider.instanceID]?.reset()
                    return
                }
                // Credential-change cleanup runs before failure handling and removes all unscoped Claude state.
                // A surviving OAuth snapshot therefore belongs to the credential observed across this refresh.
                if context.tokenAccount == nil,
                   self.snapshots[provider.instanceID] != nil,
                   self.lastSourceLabels[provider.instanceID] == "oauth"
                {
                    self.errors[provider.instanceID] = nil
                    self.failureGates[provider.instanceID]?.reset()
                    return
                }
            }
            let hadKnownUnavailableLimits = self.knownLimitsAvailabilityByProvider[provider.instanceID]?
                .isUnavailable == true
            self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
            if provider == .claude,
               ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(error.localizedDescription)
            {
                // This is a successful answer about quota availability, not a transient probe failure.
                // Drop prior limits immediately so an Education subscription notice cannot leave stale bars visible.
                self.snapshots.removeValue(forKey: provider.instanceID)
                self.lastKnownResetSnapshots.removeValue(forKey: provider.instanceID)
                self.clearSessionQuotaTransitionState(provider: provider)
                self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != provider.instanceID }
                self.lastSourceLabels.removeValue(forKey: provider.instanceID)
                self.errors[provider.instanceID] = nil
                self.knownLimitsAvailabilityByProvider[provider.instanceID] = .unavailable
                self.widgetUsagePreservationBlockedProviders.insert(provider.instanceID)
                self.failureGates[provider.instanceID]?.reset()
                return
            }
            if provider == .claude,
               hadKnownUnavailableLimits,
               Self.shouldPreservePriorSnapshot(after: error, hadPriorData: true) ||
               Self.isClaudeCLIRateLimitFailure(error)
            {
                self.errors[provider.instanceID] = nil
                self.knownLimitsAvailabilityByProvider[provider.instanceID] = .unavailable
                return
            }
            let hadPriorData = self.snapshots[provider.instanceID] != nil
            let isTerminalClaudeCLIParseFailure =
                provider == .claude &&
                hadPriorData &&
                Self.lastAvailableFailedFetchKind(from: attempts) == .cli &&
                Self.isClaudeCLIUsageParseFailure(error)
            let preservesPriorData = Self.shouldPreservePriorSnapshot(
                after: error,
                hadPriorData: hadPriorData,
                priorSnapshot: self.snapshots[provider.instanceID]) ||
                (provider == .claude &&
                    hadPriorData &&
                    (context.claudeUsesConsumerAutoPipeline ||
                        Self.isClaudeCLIRateLimitFailure(error) ||
                        isTerminalClaudeCLIParseFailure))
            let shouldSurface = self.shouldSurfaceProviderRefreshFailure(
                provider: provider,
                state: (hadPriorData, preservesPriorData, restoredClaudeHistory))
            let preservesClaudeWebSessionFailure =
                provider == .claude &&
                hadPriorData &&
                Self.isClaudeWebSessionRefreshFailure(error)
            if preservesClaudeWebSessionFailure,
               !shouldSurface
            {
                self.errors[provider.instanceID] = nil
                return
            }
            if provider == .claude,
               preservesPriorData,
               Self.isClaudeUsageProbeTimeout(error) || Self.isClaudeCLIRateLimitFailure(error)
            {
                self.errors[provider.instanceID] = nil
                return
            }
            if preservesPriorData, !shouldSurface {
                self.errors[provider.instanceID] = nil
                return
            }
            if shouldSurface {
                self.errors[provider.instanceID] = error.localizedDescription
                if !preservesPriorData, !preservesClaudeWebSessionFailure {
                    self.snapshots.removeValue(forKey: provider.instanceID)
                    if Self.tokenCostRequiresProviderSnapshot(provider) {
                        self.clearTokenSnapshot(for: provider)
                    }
                }
                self.emitHook(
                    .refreshFailed,
                    provider: provider.instanceID,
                    status: Self.refreshFailureHookStatus(error))
            } else {
                self.errors[provider.instanceID] = nil
            }
            if shouldNotifyPermissionPrompt {
                self.postPermissionPromptNotificationIfNeeded(provider: provider, error: error)
            }
        }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return }
        if let runtime = self.providerRuntimes[provider.instanceID] {
            let context = ProviderRuntimeContext(
                provider: provider, settings: self.settings, store: self)
            runtime.providerDidFail(context: context, provider: provider, error: error)
        }
    }

    private func validatedClaudeOAuthTokenAccountFallback(
        context: ProviderRefreshOutcomeContext) -> (ProviderTokenAccount, TokenAccountUsageSnapshot)?
    {
        guard let fetchedAccount = context.tokenAccount,
              let cached = context.priorTokenAccountSnapshot,
              cached.account.id == fetchedAccount.id,
              cached.sourceLabel == "oauth",
              cached.snapshot != nil,
              let currentAccount = self.uniqueTokenAccount(provider: .claude, accountID: fetchedAccount.id),
              cached.cacheKey == self.tokenAccountSnapshotCacheKey(provider: .claude, account: currentAccount)
        else {
            return nil
        }
        return (currentAccount, cached)
    }

    private func tokenAccountSnapshot(
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> TokenAccountUsageSnapshot?
    {
        guard let account else { return nil }
        return self.accountSnapshots[provider.instanceID]?.first { cached in
            cached.account.id == account.id &&
                cached.cacheKey == self.tokenAccountSnapshotCacheKey(provider: provider, account: account)
        }
    }

    nonisolated static func isPreservableNetworkTransportError(_ error: Error) -> Bool {
        let nsError = self.underlyingProviderTransportError(error) as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorCancelled,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed:
            return true
        default:
            return false
        }
    }

    static func startupConnectivityRetryDelay(forAttempt attempt: Int) -> TimeInterval? {
        let delays: [TimeInterval] = [15, 45, 120, 300]
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }

    static func isStartupConnectivityRetryableError(_ error: Error) -> Bool {
        let transportError = self.underlyingProviderTransportError(error)
        if transportError is CancellationError {
            return false
        }

        let nsError = transportError as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                return true
            default:
                return false
            }
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("timed out") ||
            message.contains("timeout") ||
            message.contains("network connection was lost") ||
            message.contains("not connected to the internet") ||
            message.contains("cannot find host") ||
            message.contains("cannot connect to host") ||
            message.contains("dns lookup")
    }

    private static func isClaudeUsageProbeTimeout(_ error: Error) -> Bool {
        if case ClaudeStatusProbeError.timedOut = error {
            return true
        }
        return error.localizedDescription == ClaudeStatusProbeError.timedOut.localizedDescription
    }

    private static func isClaudeWebSessionRefreshFailure(_ error: Error) -> Bool {
        if case ClaudeWebAPIFetcher.FetchError.unauthorized = error {
            return true
        }
        if case ClaudeWebAPIFetcher.FetchError.cloudflareChallenge = error {
            return true
        }
        return [
            ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription,
            ClaudeWebAPIFetcher.FetchError.cloudflareChallenge.localizedDescription,
        ].contains(error.localizedDescription)
    }
}
