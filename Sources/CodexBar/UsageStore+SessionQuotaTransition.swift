import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Returns a restored notice for the caller to forward to the account-scoped reset detector.
    @discardableResult
    func handleSessionQuotaTransition(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        accountDiscriminator: String? = nil,
        now _: Date = Date()) -> Bool
    {
        // Session quota notifications are tied to the primary session window. Copilot free plans can
        // expose only chat quota, so allow Copilot to fall back to secondary for transition tracking.
        // Hooks have their own enable switch, so a configured quota_reached hook must fire on a
        // real depletion even when session quota notifications are off. Run transition detection
        // whenever notifications OR a matching hook rule is active; gate the OS notification post
        // on the notification setting, but emit the hook on any depletion.
        let notificationsEnabled = self.settings.sessionQuotaNotificationsEnabled
        let hooksActive = self.hasQuotaHookRule(event: .quotaReached, provider: provider.instanceID)
        let detectionEnabled = notificationsEnabled || hooksActive
        guard let sessionWindow = self.sessionQuotaWindow(provider: provider, snapshot: snapshot) else {
            self.clearSessionQuotaTransitionState(provider: provider)
            return false
        }
        guard !sessionWindow.window.isSyntheticPlaceholder else { return false }
        let currentRemaining = sessionWindow.window.remainingPercent
        let currentSource = sessionWindow.source
        let previousState = self.sessionQuotaTransitionStates[provider.instanceID]
        let notificationAccount = accountDiscriminator
            ?? Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: snapshot)
        let evaluation = SessionQuotaTransitionReducer.evaluate(
            previous: previousState,
            observation: SessionQuotaTransitionObservation(
                provider: provider.instanceID,
                remaining: currentRemaining,
                source: currentSource,
                observedAt: snapshot.updatedAt,
                accountDiscriminator: notificationAccount),
            notificationsEnabled: detectionEnabled)
        self.sessionQuotaTransitionStates[provider.instanceID] = evaluation.state

        let providerText = provider.rawValue
        let previousRemaining = previousState?.remaining
        switch evaluation.outcome {
        case .none:
            if SessionQuotaNotificationLogic.isDepleted(currentRemaining) ||
                SessionQuotaNotificationLogic.isDepleted(previousRemaining)
            {
                let reason = self.settings.sessionQuotaNotificationsEnabled
                    ? "no transition"
                    : "notifications disabled"
                self.sessionQuotaLogger.debug(
                    "\(reason): provider=\(providerText) " +
                        "prev=\(previousRemaining ?? -1) curr=\(currentRemaining)")
            }
        case .baselineChanged:
            self.sessionQuotaLogger.debug(
                "session notification baseline changed: provider=\(providerText) curr=\(currentRemaining)")
        case .depleted, .restored:
            let transition = evaluation.outcome.transition
            self.sessionQuotaLogger.info(
                "transition \(String(describing: transition)): provider=\(providerText) " +
                    "prev=\(previousRemaining ?? -1) curr=\(currentRemaining)")
            // The account-scoped reset detector arbitrates restored and reset banners together.
            if transition == .restored, notificationsEnabled, self.settings.limitResetNotificationsEnabled {
                return true
            }
            self.postSessionQuotaTransitionIfEnabled(transition, provider: provider)
            if transition == .depleted {
                self.emitQuotaReachedHook(
                    provider: provider.instanceID,
                    sessionWindow: sessionWindow,
                    snapshot: snapshot)
            }
        }
        return false
    }

    func postSessionQuotaTransitionIfEnabled(_ transition: SessionQuotaTransition, provider: UsageProvider) {
        guard self.settings.sessionQuotaNotificationsEnabled else { return }
        self.sessionQuotaNotifier.post(transition: transition, provider: provider, badge: nil)
    }
}
