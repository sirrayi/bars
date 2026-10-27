import BarsCore
import Foundation

extension UsageStore {
    struct ProviderRefreshOutcomeContext {
        let generation: UInt64
        let claudeUsesConsumerAutoPipeline: Bool
        let tokenAccount: ProviderTokenAccount?
        let priorTokenAccountSnapshot: TokenAccountUsageSnapshot?
        let claudeOAuthHistoryPersistentRefHash: String?
        let claudeOAuthActiveAccountObservation: ClaudeOAuthActiveAccountObservation
        var claudeCredentialFingerprint: String?
    }

    func credentialAccount(provider: UsageProvider, context: ProviderRefreshOutcomeContext) -> String {
        if let account = Self.warningTokenAccountDiscriminator(context.tokenAccount) { return account }
        // Provider-specific by design: ambient CLI accounts use the refresh's already-validated ownership evidence.
        if provider == .claude {
            let identity: String? = if case let .stable(identity) = context.claudeOAuthActiveAccountObservation {
                identity
            } else { nil }
            return self.claudeCredentialNotificationScope(
                identity: identity,
                fingerprint: context.claudeCredentialFingerprint)
        }
        return "default"
    }

    private func warningAccountDiscriminators(
        provider: UsageProvider,
        result: ProviderFetchResult,
        context: ProviderRefreshOutcomeContext) -> (quota: String?, source: String?, requiresKnownAccount: Bool)
    {
        // Provider-specific by design: warning scopes follow verified Claude account bindings.
        let requiresKnownAccount = provider == .claude && [.oauth, .cli].contains(result.strategyKind)
        if let tokenAccount = context.tokenAccount {
            let key = Self.warningTokenAccountDiscriminator(tokenAccount)
            return (key, key, requiresKnownAccount)
        }
        guard provider == .claude else { return (nil, nil, requiresKnownAccount) }
        let scopes = self.warningClaudeAccountDiscriminators(
            strategyKind: result.strategyKind,
            observation: result.strategyKind == .cli || result.claudeOAuthCredentialOwner == .claudeCLI
                ? context.claudeOAuthActiveAccountObservation : .changed,
            oauthHistoryOwnerIdentifier: result.claudeOAuthHistoryOwnerIdentifier)
        return (scopes.quota, scopes.source, requiresKnownAccount)
    }

    func handleProviderRefreshNotifications(
        provider: UsageProvider,
        result: ProviderFetchResult,
        snapshot: UsageSnapshot,
        context: ProviderRefreshOutcomeContext) -> (account: String?, sessionRestored: Bool)
    {
        self.handleCredentialOutcome(
            provider: provider,
            account: self.credentialAccount(provider: provider, context: context),
            result: .success(result))
        let warningAccounts = self.warningAccountDiscriminators(
            provider: provider,
            result: result,
            context: context)
        self.handleQuotaWarningTransitions(
            provider: provider,
            snapshot: snapshot,
            accountDiscriminator: warningAccounts.quota,
            hookAccountDiscriminator: warningAccounts.source,
            requiresKnownAccount: warningAccounts.requiresKnownAccount)
        let sessionRestored = self.handleSessionQuotaTransition(
            provider: provider,
            snapshot: snapshot,
            accountDiscriminator: warningAccounts.quota)
        self.handlePredictivePaceWarningTransitions(
            provider: provider,
            snapshot: snapshot,
            accountDiscriminatorOverride: warningAccounts.source,
            requiresKnownAccount: warningAccounts.requiresKnownAccount)
        return (warningAccounts.source, sessionRestored)
    }
}
