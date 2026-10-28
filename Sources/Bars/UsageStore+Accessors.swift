import BarsCore
import Foundation

extension UsageStore {
    var statusChecksEnabled: Bool {
        self.settings.statusChecksEnabled
    }

    /// Compile-time implementation kinds for provider-specific fetch and bespoke UI boundaries.
    func enabledFirstPartyProviders() -> [UsageProvider] {
        self.enabledProviders().compactMap(\.firstPartyProvider)
    }

    func enabledFirstPartyProvidersForDisplay() -> [UsageProvider] {
        self.enabledProvidersForDisplay().compactMap(\.firstPartyProvider)
    }

    func enabledFirstPartyProvidersForBackgroundWork() -> [UsageProvider] {
        self.enabledProvidersForBackgroundWork().compactMap(\.firstPartyProvider)
    }

    struct DeepSeekProfileTransition {
        var snapshot: UsageSnapshot
        let accountID: UUID?
        let hasSyntheticBalance: Bool
    }

    func version(for provider: UsageProvider) -> String? {
        self.versions[provider.instanceID]
    }

    var claudeSnapshot: UsageSnapshot? {
        // Provider-specific by design: Claude swap/account consumers require the active Claude snapshot directly.
        self.snapshots[.claude]
    }

    func presentationSnapshot(for provider: UsageProvider) -> UsageSnapshot? {
        // Provider-specific by design: DeepSeek profile transitions overlay live state.
        if provider == .deepseek,
           let transition = self.deepseekProfileTransition,
           transition.accountID == self.settings.selectedTokenAccount(for: .deepseek)?.id
        {
            return transition.snapshot
        }
        if let snapshot = self.snapshot(for: provider.instanceID) {
            return snapshot
        }
        guard provider == .deepseek, self.refreshingProviders.contains(provider.instanceID) else { return nil }
        return self.lastKnownResetSnapshots[provider.instanceID]
    }

    func beginDeepSeekProfileTransition(preservingBalance: Bool = true) {
        guard self.deepseekProfileTransition == nil,
              let snapshot = self.snapshots[.deepseek] ?? self.lastKnownResetSnapshots[.deepseek]
        else { return }
        var transitionSnapshot = snapshot.withoutDeepSeekDetailedUsage()
        if !preservingBalance {
            transitionSnapshot = transitionSnapshot.with(
                primary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: L("Refreshing")),
                secondary: nil)
        }
        self.deepseekProfileTransition = DeepSeekProfileTransition(
            snapshot: transitionSnapshot,
            accountID: self.settings.selectedTokenAccount(for: .deepseek)?.id,
            hasSyntheticBalance: !preservingBalance)
    }

    func markDeepSeekProfileTransitionUnavailable() {
        guard var transition = self.deepseekProfileTransition,
              transition.hasSyntheticBalance
        else { return }
        transition.snapshot = transition.snapshot.with(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: L("Unavailable")),
            secondary: nil)
        self.deepseekProfileTransition = transition
    }

    func clearDeepSeekProfileTransition() {
        self.deepseekProfileTransition = nil
    }

    var deepseekProfileTransitionSnapshot: UsageSnapshot? {
        self.deepseekProfileTransition?.snapshot
    }

    var lastClaudeError: String? {
        // Provider-specific by design: Claude swap/account surfaces consume the active Claude error lane directly.
        self.errors[.claude]
    }

    func error(for provider: UsageProvider) -> String? {
        self.errors[provider.instanceID]
    }

    func diagnostic(for provider: UsageProvider) -> String? {
        self.diagnostics[provider.instanceID]
    }

    func userFacingError(for provider: UsageProvider) -> String? {
        guard let presentation = self.userFacingErrorPresentation(for: provider) else { return nil }
        guard let capturedAt = presentation.lastKnownUsageCapturedAt else { return presentation.message }
        return presentation.message + " " + LastKnownUsagePresentation.message(capturedAt: capturedAt)
    }

    func userFacingErrorPresentation(
        for provider: UsageProvider) -> (message: String, lastKnownUsageCapturedAt: Date?)?
    {
        if let raw = self.errors[provider.instanceID] {
            switch provider {
            case .claude:
                return ClaudeUIErrorMapper.userFacingMessage(
                    raw,
                    staleSnapshotUpdatedAt: nil).map { ($0, self.snapshots[provider.instanceID]?.updatedAt) }
            default:
                return (L(raw), nil)
            }
        }
        if let diagnostic = self.diagnostics[provider.instanceID] {
            return (diagnostic, nil)
        }
        return self.unavailableMessage(for: provider).map { ($0, nil) }
    }

    func unavailableMessage(for provider: UsageProvider) -> String? {
        guard self.enabledProvidersForDisplay().contains(provider.instanceID),
              !self.isProviderAvailable(provider)
        else {
            return nil
        }

        if let adapter = ProviderDescriptorRegistry.descriptor(for: provider).credentials {
            let environment = ProviderRegistry.makeEnvironment(
                base: self.environmentBase,
                provider: provider,
                settings: self.settings,
                tokenOverride: nil)
            if let message = adapter.unavailableMessage(environment: environment) {
                return message
            }
        }

        return "\(self.metadata(for: provider).displayName) is unavailable in the current environment."
    }

    func status(for provider: UsageProvider) -> ProviderStatus? {
        guard self.statusChecksEnabled else { return nil }
        return self.statuses[provider.instanceID]
    }

    func statusComponents(for provider: UsageProvider) -> [ProviderStatusComponent] {
        guard self.statusChecksEnabled else { return [] }
        return self.statusComponents[provider.instanceID] ?? []
    }

    /// Fallback identity for providers without snapshot identity. Retained providers carry their own
    /// identity in snapshots, so the fallback never borrows another provider's account.
    func accountInfo(for _: UsageProvider) -> AccountInfo {
        AccountInfo(email: nil, plan: nil)
    }
}
