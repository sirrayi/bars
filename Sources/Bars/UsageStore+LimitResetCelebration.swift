import BarsCore
import Foundation

extension UsageStore {
    private nonisolated static let limitResetThreshold = 1.0
    private nonisolated static let claudeWeeklyRecoveryObservationCount = 2

    struct LimitResetDetectorState: Codable, Equatable {
        let wasAboveThreshold: Bool
        let lastObservedAt: Date
        let sourceRawValue: String?
        var resetBoundary: Date?
        var recoveryAboveThresholdCount: Int?
        /// Identity-less Claude CLI samples share one detector key and can be transient.
        /// Require a second low sample before celebrating an apparent reset from that key.
        var pendingLowConfirmation: Bool
        var notificationReceipt: LimitResetNotificationReceipt?
        var lastNotifiedResetBoundary: Date?

        init(
            wasAboveThreshold: Bool,
            lastObservedAt: Date,
            sourceRawValue: String?,
            resetBoundary: Date? = nil,
            recoveryAboveThresholdCount: Int? = nil,
            pendingLowConfirmation: Bool = false,
            notificationReceipt: LimitResetNotificationReceipt? = nil,
            lastNotifiedResetBoundary: Date? = nil)
        {
            self.wasAboveThreshold = wasAboveThreshold
            self.lastObservedAt = lastObservedAt
            self.sourceRawValue = sourceRawValue
            self.resetBoundary = resetBoundary
            self.recoveryAboveThresholdCount = recoveryAboveThresholdCount
            self.pendingLowConfirmation = pendingLowConfirmation
            self.notificationReceipt = notificationReceipt
            self.lastNotifiedResetBoundary = lastNotifiedResetBoundary
        }

        private enum CodingKeys: String, CodingKey {
            case wasAboveThreshold
            case lastObservedAt
            case sourceRawValue
            case resetBoundary
            case recoveryAboveThresholdCount
            case pendingLowConfirmation
            case notificationReceipt
            case lastNotifiedResetBoundary
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.wasAboveThreshold = try container.decode(Bool.self, forKey: .wasAboveThreshold)
            self.lastObservedAt = try container.decode(Date.self, forKey: .lastObservedAt)
            self.sourceRawValue = try container.decodeIfPresent(String.self, forKey: .sourceRawValue)
            self.resetBoundary = try container.decodeIfPresent(Date.self, forKey: .resetBoundary)
            self.recoveryAboveThresholdCount = try container.decodeIfPresent(
                Int.self,
                forKey: .recoveryAboveThresholdCount)
            self.pendingLowConfirmation = try container.decodeIfPresent(
                Bool.self,
                forKey: .pendingLowConfirmation) ?? false
            self.notificationReceipt = try container.decodeIfPresent(
                LimitResetNotificationReceipt.self, forKey: .notificationReceipt)
            self.lastNotifiedResetBoundary = try container.decodeIfPresent(
                Date.self,
                forKey: .lastNotifiedResetBoundary)
        }
    }

    struct LimitResetDetectionContext {
        let provider: UsageProvider
        let account: ProviderTokenAccount?
        let snapshot: UsageSnapshot
        let accountKey: String?
        let capturedAt: Date
        let sessionRestoredNotificationPending: Bool
    }

    struct LimitResetObservation {
        let usedPercent: Double
        let observedAt: Date
        let resetBoundary: Date?
        let source: SessionQuotaWindowSource?
    }

    struct LimitResetDetectionDescriptor {
        let seriesName: PlanUtilizationSeriesName
        let defaultsKey: String
        let resetKind: String
    }

    struct LimitResetDetectorTransitionInput {
        let provider: ProviderInstanceID
        let snapshot: UsageSnapshot
        let seriesName: PlanUtilizationSeriesName
        let observation: LimitResetObservation
        let previousState: LimitResetDetectorState?
        let requiresLowConfirmation: Bool
    }

    struct LimitResetDetectorTransition {
        let state: LimitResetDetectorState
        let shouldPost: Bool
        let claudeWeeklyRecoveryPending: Bool
        let nextRecoveryCount: Int
    }

    func postLimitResetCelebrationIfNeeded(
        states: inout [String: LimitResetDetectorState],
        context: LimitResetDetectionContext,
        descriptor: LimitResetDetectionDescriptor,
        observation: LimitResetObservation?)
    {
        let restored = descriptor.seriesName == .session && context.sessionRestoredNotificationPending
        guard let observation else {
            if restored { self.postSessionQuotaTransitionIfEnabled(.restored, provider: context.provider) }
            return
        }

        guard let accountIdentifier = self.limitResetAccountIdentifier(
            provider: context.provider,
            account: context.account,
            snapshot: context.snapshot,
            accountKey: context.accountKey)
        else {
            if restored { self.postSessionQuotaTransitionIfEnabled(.restored, provider: context.provider) }
            return
        }
        let detectorKey = Self.limitResetDetectorStateKey(
            provider: context.provider.instanceID,
            accountIdentifier: accountIdentifier)
        let requiresLowConfirmation = context.provider == .claude
            && accountIdentifier == context.provider.rawValue
        let currentUsed = observation.usedPercent
        let currentObservedAt = observation.observedAt
        if let existingState = states[detectorKey],
           currentObservedAt <= existingState.lastObservedAt
        {
            return
        }

        let previousState = states[detectorKey]
        let transition = Self.limitResetDetectorTransition(
            input: LimitResetDetectorTransitionInput(
                provider: context.provider.instanceID,
                snapshot: context.snapshot,
                seriesName: descriptor.seriesName,
                observation: observation,
                previousState: previousState,
                requiresLowConfirmation: requiresLowConfirmation))
        var state = transition.state
        let notice = self.prepareLimitResetNotification(
            state: &state,
            previousState: previousState,
            observation: observation,
            resetConfirmed: transition.shouldPost,
            restored: restored)
        states[detectorKey] = state
        self.persistPlanUtilizationStates(
            states,
            defaultsKey: descriptor.defaultsKey,
            logName: descriptor.resetKind)
        if let notice {
            switch notice {
            case .restored:
                self.postSessionQuotaTransitionIfEnabled(.restored, provider: context.provider)
            case .reset:
                self.postLimitResetNotificationIfNeeded(
                    provider: context.provider,
                    window: descriptor.seriesName == .session ? .session : .weekly,
                    accountLabel: self.limitResetAccountLabel(
                        provider: context.provider, account: context.account, snapshot: context.snapshot))
            }
        }

        if transition.claudeWeeklyRecoveryPending, currentUsed > Self.limitResetThreshold {
            BarsLog.logger(LogCategories.confetti).debug(
                "Confirming Claude weekly usage recovery after celebration",
                metadata: [
                    "accountIdentifier": accountIdentifier,
                    "confirmationCount": String(transition.nextRecoveryCount),
                    "observedAt": String(format: "%.0f", currentObservedAt.timeIntervalSince1970),
                ])
        }

        guard transition.shouldPost else { return }
        let accountLabel = self.limitResetAccountLabel(
            provider: context.provider,
            account: context.account,
            snapshot: context.snapshot)

        BarsLog.logger(LogCategories.confetti).info(
            "\(descriptor.resetKind.capitalized) limit reset",
            metadata: [
                "provider": context.provider.rawValue,
                "accountIdentifier": accountIdentifier,
                "accountLabel": accountLabel ?? "",
                "resetKind": descriptor.resetKind,
                "usedPercent": String(format: "%.2f", currentUsed),
                "observedAt": String(format: "%.0f", currentObservedAt.timeIntervalSince1970),
            ])
        switch descriptor.seriesName {
        case .session:
            self.emitQuotaResetHook(
                provider: context.provider.instanceID,
                window: .session,
                usedPercent: currentUsed,
                accountLabel: accountLabel)
            let event = SessionLimitResetEvent(
                provider: context.provider,
                accountIdentifier: accountIdentifier,
                accountLabel: accountLabel,
                usedPercent: currentUsed)
            NotificationCenter.default.post(name: .barsSessionLimitReset, object: event)
        case .weekly:
            self.emitQuotaResetHook(
                provider: context.provider.instanceID,
                window: .weekly,
                usedPercent: currentUsed,
                accountLabel: accountLabel)
            let event = WeeklyLimitResetEvent(
                provider: context.provider,
                accountIdentifier: accountIdentifier,
                accountLabel: accountLabel,
                usedPercent: currentUsed)
            NotificationCenter.default.post(name: .barsWeeklyLimitReset, object: event)
        default:
            return
        }
    }

    nonisolated static func limitResetDetectorTransition(
        input: LimitResetDetectorTransitionInput) -> LimitResetDetectorTransition
    {
        let observation = input.observation
        let previousState = input.previousState
        let currentUsed = observation.usedPercent
        let wasAboveThreshold = currentUsed > self.limitResetThreshold
        let isClaudeWeekly = input.provider == .claude && input.seriesName == .weekly
        let claudeWeeklyRecoveryPending = isClaudeWeekly
            && previousState?.recoveryAboveThresholdCount != nil
        let sourceRawValue = observation.source?.rawValue
        let sourceChanged = input.seriesName == .session
            && previousState?.sourceRawValue != nil
            && previousState?.sourceRawValue != sourceRawValue
        let resetBoundaryAllowsPost = self.limitResetBoundaryAllowsPost(input: input)
        let crossedBelowThreshold = !sourceChanged
            && previousState?.wasAboveThreshold == true
            && !wasAboveThreshold
        let confirmingLowSample = !sourceChanged
            && previousState?.pendingLowConfirmation == true
            && !wasAboveThreshold
        let shouldPost = if input.requiresLowConfirmation {
            confirmingLowSample && !claudeWeeklyRecoveryPending
        } else {
            crossedBelowThreshold && resetBoundaryAllowsPost && !claudeWeeklyRecoveryPending
        }
        let suppressedGuardedCrossing = crossedBelowThreshold && !resetBoundaryAllowsPost
        let shouldAwaitLowConfirmation = input.requiresLowConfirmation
            && crossedBelowThreshold
            && !confirmingLowSample
            && resetBoundaryAllowsPost
            && !claudeWeeklyRecoveryPending
        // Sessions retain the last non-regressed boundary on every guarded sample.
        let shouldPreserveBoundary = !sourceChanged
            && !resetBoundaryAllowsPost
            && (input.seriesName == .session || previousState?.resetBoundary != nil)
        let previousRecoveryCount = previousState?.recoveryAboveThresholdCount ?? 0
        let nextRecoveryCount = if claudeWeeklyRecoveryPending {
            wasAboveThreshold ? previousRecoveryCount + 1 : 0
        } else {
            0
        }
        let claudeWeeklyRecoveryConfirmed = claudeWeeklyRecoveryPending
            && nextRecoveryCount >= self.claudeWeeklyRecoveryObservationCount
        let nextWasAboveThreshold = if shouldPost {
            false
        } else if claudeWeeklyRecoveryPending {
            claudeWeeklyRecoveryConfirmed
        } else if suppressedGuardedCrossing || shouldAwaitLowConfirmation {
            true
        } else {
            wasAboveThreshold
        }
        let persistedRecoveryCount: Int? = if shouldPost {
            0
        } else if claudeWeeklyRecoveryPending, !claudeWeeklyRecoveryConfirmed {
            nextRecoveryCount
        } else {
            nil
        }
        let state = LimitResetDetectorState(
            // A transient zero must not erase the baseline needed to recognize the real reset that follows.
            wasAboveThreshold: nextWasAboveThreshold,
            lastObservedAt: observation.observedAt,
            sourceRawValue: sourceRawValue,
            resetBoundary: shouldPreserveBoundary ? previousState?.resetBoundary : observation.resetBoundary,
            recoveryAboveThresholdCount: persistedRecoveryCount,
            pendingLowConfirmation: shouldAwaitLowConfirmation,
            notificationReceipt: previousState?.notificationReceipt,
            lastNotifiedResetBoundary: previousState?.lastNotifiedResetBoundary)
        return LimitResetDetectorTransition(
            state: state,
            shouldPost: shouldPost,
            claudeWeeklyRecoveryPending: claudeWeeklyRecoveryPending,
            nextRecoveryCount: nextRecoveryCount)
    }

    private nonisolated static func limitResetBoundaryAllowsPost(
        input: LimitResetDetectorTransitionInput) -> Bool
    {
        if input.seriesName == .session {
            return self.limitResetBoundaryAdvanced(
                previous: input.previousState?.resetBoundary,
                current: input.observation.resetBoundary)
        }
        return true
    }
}
