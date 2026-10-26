import CodexBarCore
import Foundation

struct CurrentProviderConfigTokenSnapshot: Sendable, Equatable {
    let snapshot: CostUsageTokenSnapshot
    let publicationRevision: UInt64
}

struct CurrentProviderConfigTokenPublication: Sendable, Equatable {
    let snapshot: CostUsageTokenSnapshot?
    let publicationRevision: UInt64
}

struct TokenSnapshotPublication: Sendable, Equatable {
    let snapshot: CostUsageTokenSnapshot?
    let publicationRevision: UInt64
    let providerConfigRevision: UInt64
    let scopeSignature: String
}

extension UsageStore {
    func logTokenUsageSuccess(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        historyDays: Int,
        startedAt: Date)
    {
        let durationText = String(format: "%.2f", Date().timeIntervalSince(startedAt))
        let sessionCost = snapshot.sessionCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let monthCost = snapshot.last30DaysCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let message =
            "cost usage success provider=\(provider.rawValue) " +
            "duration=\(durationText)s " +
            "today=\(sessionCost) " +
            "historyDays=\(historyDays) windowCost=\(monthCost)"
        self.tokenCostLogger.info(message)
    }

    func loadTokenUsageSnapshot(
        provider: UsageProvider,
        force: Bool,
        now: Date,
        historyDays: Int,
        reportContext: CostUsageReportContext = .regular) async throws -> CostUsageTokenResult
    {
        if let override = self._test_tokenUsageResultLoaderOverride {
            return try await override(provider, force, now, historyDays)
        }
        if let override = self._test_tokenUsageSnapshotLoaderOverride {
            let snapshot = try await override(provider, force, now, historyDays)
            return CostUsageTokenResult(snapshot: snapshot)
        }

        let fetcher = self.costUsageFetcher
        let timeoutSeconds = self.tokenFetchTimeout
        // Provider-specific by design: mapped Claude costs include only the declared account directory.
        let claudeDirectory = provider == .claude ? self.claudeTokenCostConfigDirectory : nil
        let environment = self.environmentBase
        return try await withThrowingTaskGroup(of: CostUsageTokenResult.self) { group in
            group.addTask(priority: .utility) {
                try await fetcher.loadTokenResult(
                    provider: provider,
                    claudeConfigDirectory: claudeDirectory,
                    environment: environment,
                    now: now,
                    forceRefresh: force,
                    historyDays: historyDays,
                    bypassScannerDebounce: true,
                    calendar: self.settings.costUsageBucketCalendar,
                    reportContext: reportContext)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw CostUsageError.timedOut(seconds: Int(timeoutSeconds))
            }
            defer { group.cancelAll() }
            guard let snapshot = try await group.next() else { throw CancellationError() }
            return snapshot
        }
    }

    func tokenSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        // Provider-specific by design: never show a previous mapped directory after an account switch or clear.
        if provider == .claude,
           self.claudeTokenCostConfigDirectory != nil ||
           self.tokenSnapshotPublications[provider.instanceID]?.scopeSignature.hasPrefix("claude:directory:") == true
        {
            return self.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot
        }
        return self.tokenSnapshotPublications[provider.instanceID]?.snapshot
    }

    func tokenSnapshotForCurrentProviderConfig(
        for provider: UsageProvider) -> CurrentProviderConfigTokenSnapshot?
    {
        guard let publication = self.tokenSnapshotPublicationForCurrentProviderConfig(for: provider),
              let snapshot = publication.snapshot
        else { return nil }
        return CurrentProviderConfigTokenSnapshot(
            snapshot: snapshot,
            publicationRevision: publication.publicationRevision)
    }

    func tokenSnapshotPublicationForCurrentProviderConfig(
        for provider: UsageProvider) -> CurrentProviderConfigTokenPublication?
    {
        guard let publication = self.tokenSnapshotPublications[provider.instanceID],
              publication.providerConfigRevision == self.settings.providerConfigRevision(for: provider),
              publication.scopeSignature == self.tokenSnapshotScopeSignature(for: provider)
        else { return nil }
        return CurrentProviderConfigTokenPublication(
            snapshot: publication.snapshot,
            publicationRevision: publication.publicationRevision)
    }

    func tokenSnapshotPublicationRevision(for provider: UsageProvider) -> UInt64 {
        self.tokenSnapshotPublicationRevisions[provider.instanceID] ?? 0
    }

    enum TokenSnapshotError: LocalizedError {
        case historyUnavailable

        var errorDescription: String? {
            "Local token history is unavailable or incomplete."
        }
    }

    func publishTokenSnapshot(
        _ snapshot: CostUsageTokenSnapshot,
        for provider: UsageProvider)
    {
        self.publishTokenSnapshotState(snapshot, for: provider)
    }

    func publishConfirmedEmptyTokenSnapshot(for provider: UsageProvider) {
        self.publishTokenSnapshotState(nil, for: provider)
    }

    private func publishTokenSnapshotState(
        _ snapshot: CostUsageTokenSnapshot?,
        for provider: UsageProvider)
    {
        self.tokenSnapshotPublicationRevisions[provider.instanceID, default: 0] &+= 1
        self.installCachedTokenSnapshot(snapshot, for: provider)
        self.synchronizeSharedSpendDashboardAfterTokenPublication(for: provider)
    }

    /// The menu card projects quota weeks synchronously while it builds, so the per-slice pass runs
    /// off the main actor when possible; a card arriving first can still build it synchronously.
    private func warmQuotaProjection(for snapshot: CostUsageTokenSnapshot?) {
        guard let snapshot, !snapshot.quotaSlices.isEmpty || !snapshot.hourly.isEmpty else { return }
        let calendar = self.settings.costUsageBucketCalendar
        Task.detached(priority: .utility) {
            snapshot.warmQuotaProjection(calendar: calendar)
        }
    }

    func installCachedTokenSnapshot(
        _ snapshot: CostUsageTokenSnapshot?,
        for provider: UsageProvider)
    {
        self.tokenSnapshotPublications[provider.instanceID] = TokenSnapshotPublication(
            snapshot: snapshot?.reporting(self.settings.costReportingPeriod),
            publicationRevision: self.tokenSnapshotPublicationRevision(for: provider),
            providerConfigRevision: self.settings.providerConfigRevision(for: provider),
            scopeSignature: self.tokenSnapshotScopeSignature(for: provider))
        self.warmQuotaProjection(for: snapshot)
    }

    func clearTokenSnapshot(for provider: UsageProvider) {
        self.tokenSnapshotPublications.removeValue(forKey: provider.instanceID)
    }

    func clearTokenSnapshots() {
        self.tokenSnapshotPublications.removeAll()
        self.spendDashboardTokenPublications.removeAll()
        self.spendDashboardTokenPublicationRevisions.removeAll()
        self.spendDashboardTokenIncorporatedTriggers.removeAll()
        self.spendDashboardTokenFailedTriggers.removeAll()
    }

    func installProviderDerivedTokenSnapshot(from snapshot: UsageSnapshot, for provider: UsageProvider) {
        guard Self.tokenCostRequiresProviderSnapshot(provider) else { return }
        if let tokenSnapshot = self.tokenSnapshot(fromProviderSnapshot: snapshot, provider: provider) {
            self.installCachedTokenSnapshot(tokenSnapshot, for: provider)
        } else {
            self.clearTokenSnapshot(for: provider)
        }
        self.tokenErrors[provider.instanceID] = nil
        self.tokenFailureGates[provider.instanceID]?.recordSuccess()
    }

    func publishProviderDerivedTokenSnapshot(from snapshot: UsageSnapshot, for provider: UsageProvider) {
        guard Self.tokenCostRequiresProviderSnapshot(provider) else { return }
        if let tokenSnapshot = self.tokenSnapshot(fromProviderSnapshot: snapshot, provider: provider) {
            self.publishTokenSnapshot(tokenSnapshot, for: provider)
        } else {
            self.publishConfirmedEmptyTokenSnapshot(for: provider)
        }
        self.tokenErrors[provider.instanceID] = nil
        self.tokenFailureGates[provider.instanceID]?.recordSuccess()
    }

    func resetProviderDerivedTokenSnapshot(for provider: UsageProvider) {
        guard Self.tokenCostRequiresProviderSnapshot(provider) else { return }
        self.clearTokenSnapshot(for: provider)
        self.tokenErrors[provider.instanceID] = nil
        self.tokenFailureGates[provider.instanceID]?.reset()
    }

    func clearProviderDerivedTokenSnapshot(for provider: UsageProvider) {
        guard Self.tokenCostRequiresProviderSnapshot(provider) else { return }
        self.clearTokenSnapshot(for: provider)
    }

    func tokenError(for provider: UsageProvider) -> String? {
        self.tokenErrors[provider.instanceID]
    }

    func tokenLastAttemptAt(for provider: UsageProvider) -> Date? {
        self.lastTokenFetchAt[provider.instanceID]
    }

    func isTokenRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.tokenRefreshInFlight.contains(provider.instanceID)
    }

    func tokenCostRefreshIsActive(for provider: UsageProvider) -> Bool {
        self.tokenRefreshInFlight.contains(provider.instanceID)
    }

    func tokenCostScopeSignature(for provider: UsageProvider) -> String {
        if provider == .claude, let directory = self.claudeTokenCostConfigDirectory {
            return "claude:directory:\(directory)"
        }
        return provider.rawValue
    }

    func tokenSnapshotScopeSignature(for provider: UsageProvider) -> String {
        self.tokenSnapshotScopeSignature(
            for: provider,
            historyDays: self.settings.costUsageHistoryDays,
            includeSettingsRevision: true)
    }

    func spendDashboardTokenSnapshotScopeSignature(for provider: UsageProvider) -> String {
        self.tokenSnapshotScopeSignature(
            for: provider,
            historyDays: SpendDashboardSource.scanDays,
            includeSettingsRevision: false)
    }

    func tokenSnapshotScopeSignature(
        for provider: UsageProvider,
        historyDays: Int,
        includeSettingsRevision: Bool) -> String
    {
        var base = "\(self.tokenCostScopeSignature(for: provider))|historyDays=\(historyDays)"
        if includeSettingsRevision {
            base += "|settingsRevision=\(self.settings.costUsageSettingsRevision)|"
                + self.settings.costReportingPeriod.identity(
                    now: Date(),
                    calendar: self.settings.costUsageBucketCalendar)
        }
        return base
    }

    func tokenRefreshCanReuseCurrentSnapshot(
        provider: UsageProvider,
        now: Date,
        costScopeSignature: String) -> Bool
    {
        guard self.tokenSnapshotPublicationForCurrentProviderConfig(for: provider) != nil,
              let last = self.lastTokenFetchAt[provider.instanceID],
              self.lastTokenFetchScope[provider.instanceID] == costScopeSignature
        else {
            return false
        }
        guard let tokenFetchTTL = self.tokenFetchTTL else { return false }
        return now.timeIntervalSince(last) < tokenFetchTTL
    }

    struct TokenRefreshPublicationScope {
        let publicationRevision: ProviderPublicationRevision
        let providerConfigRevision: UInt64
        let costSettingsRevision: UInt64
        let historyDays: Int
        let signature: String
    }

    struct TokenFetchFailureCooldown {
        let attemptedAt: Date
        let retryAfter: Date
        let scope: TokenRefreshPublicationScope
    }

    func tokenRefreshFailureIsCoolingDown(provider: UsageProvider, now: Date) -> Bool {
        guard let failure = self.tokenFetchFailureCooldowns[provider.instanceID],
              self.tokenFetchTTL != nil,
              now >= failure.attemptedAt,
              now < failure.retryAfter
        else { return false }
        // A failed query may have no snapshot, but still owns its account, settings, and provider lifecycle scope.
        return self.tokenRefreshPublicationDisposition(provider: provider, scope: failure.scope) == .current
    }

    func tokenRefreshPublicationScope(
        for provider: UsageProvider,
        historyDays: Int,
        costScopeSignature: String) -> TokenRefreshPublicationScope
    {
        TokenRefreshPublicationScope(
            publicationRevision: self.providerPublicationRevision(for: provider),
            providerConfigRevision: self.settings.providerConfigRevision(for: provider),
            costSettingsRevision: self.settings.costUsageSettingsRevision,
            historyDays: historyDays,
            signature: costScopeSignature)
    }

    enum TokenRefreshPublicationDisposition {
        case current
        case scopeChanged
        case unchangedCredentialMismatch
    }

    func tokenRefreshPublicationDisposition(
        provider: UsageProvider,
        scope: TokenRefreshPublicationScope,
        _ fetchedCredentialScopeFingerprint: String? = nil) -> TokenRefreshPublicationDisposition
    {
        guard self.providerPublicationRevisionIsCurrent(scope.publicationRevision, for: provider),
              self.settings.providerConfigRevision(for: provider) == scope.providerConfigRevision,
              self.settings.costUsageSettingsRevision == scope.costSettingsRevision,
              self.settings.isCostUsageEffectivelyEnabled(for: provider),
              self.isEnabled(provider),
              self.settings.costUsageHistoryDays == scope.historyDays
        else {
            return .scopeChanged
        }
        let currentSignature = self.tokenSnapshotScopeSignature(for: provider)

        return currentSignature == scope.signature ? .current : .scopeChanged
    }

    func tokenSnapshot(
        fromProviderSnapshot snapshot: UsageSnapshot?,
        provider: UsageProvider,
        historyDays: Int? = nil)
        -> CostUsageTokenSnapshot?
    {
        let windowDays = historyDays ?? self.settings.costUsageHistoryDays
        let result: CostUsageTokenSnapshot? = switch provider {
        case .opencodego:
            // Web-only source mode and machines with no readable local database leave
            // `opencodegoUsage.daily` empty; a non-nil-but-dataless projection would still
            // surface a Cost row whose history submenu has nothing to render.
            snapshot?.opencodegoUsage.flatMap { usage in
                usage.daily.isEmpty ? nil : usage
                    .toCostUsageTokenSnapshot(historyDays: windowDays)
            }
        default:
            nil
        }
        guard historyDays == nil else { return result }
        return result?.selecting(
            self.settings.costReportingPeriod,
            now: Date(),
            calendar: self.settings.costUsageBucketCalendar)
    }

    nonisolated static func tokenCostRequiresProviderSnapshot(_ provider: UsageProvider) -> Bool {
        // Provider-specific by design: these providers project live usage snapshots into the
        // shared spend catalog instead of running the local CostUsageFetcher JSONL pipeline.
        switch provider {
        case .opencodego:
            true
        default:
            false
        }
    }

    nonisolated static func costUsageCacheDirectory(
        fileManager: FileManager = .default) -> URL
    {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
    }

    func clearCostUsageCache(
        fileManagerFactory: @escaping @Sendable () -> FileManager = { .default }) async -> String?
    {
        let errorMessage: String? = await Task.detached(priority: .utility) {
            let fileManager = fileManagerFactory()
            do {
                try fileManager.removeItem(at: Self.costUsageCacheDirectory(fileManager: fileManager))
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
                    return nil
                }
                return error.localizedDescription
            }
            return nil
        }.value

        guard errorMessage == nil else { return errorMessage }

        self.clearTokenSnapshots()
        self.tokenErrors.removeAll()
        self.lastTokenFetchAt.removeAll()
        self.lastTokenFetchScope.removeAll()
        self.tokenFetchFailureCooldowns.removeAll()
        self.tokenFailureGates[.claude]?.reset()
        return nil
    }

    /// Descriptors live in CodexBarCore and cannot localize, so the message is resolved here.
    /// `L` returns its argument unchanged for providers whose message is a plain English literal.
    nonisolated static func tokenCostNoDataMessage(for provider: UsageProvider) -> String {
        L(ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.noDataMessage())
    }

    func regularTokenSnapshotIsConfirmedEmpty(
        _ snapshot: CostUsageTokenSnapshot,
        for provider: UsageProvider) throws -> Bool
    {
        guard snapshot.daily.isEmpty, snapshot.meteredCostUSD == nil else { return false }
        guard snapshot.historyCoverageIsEstablished else {
            throw TokenSnapshotError.historyUnavailable
        }
        return true
    }

    struct TokenUsageRefreshContext {
        let provider: UsageProvider
        let now: Date
        let historyDays: Int
        let costScopeSignature: String
        let publicationScope: TokenRefreshPublicationScope
        let startedAt: Date
    }

    func commitTokenUsageResult(
        _ result: CostUsageTokenResult,
        context: TokenUsageRefreshContext) throws
    {
        let snapshot = result.snapshot
        try Task.checkCancellation()
        let completedCostScopeSignature = context.costScopeSignature
        let disposition = self.tokenRefreshPublicationDisposition(
            provider: context.provider,
            scope: context.publicationScope)
        guard disposition == .current else {
            self.clearTokenFetchMetadataIfMatching(
                provider: context.provider,
                attemptedAt: context.now,
                costScopeSignature: context.costScopeSignature)
            if disposition == .scopeChanged {
                self.requestTokenRefreshAfterStaleCompletion(for: context.provider)
            }
            return
        }
        self.lastTokenFetchScope[context.provider.instanceID] = completedCostScopeSignature

        if try self.regularTokenSnapshotIsConfirmedEmpty(snapshot, for: context.provider) {
            self.publishConfirmedEmptyTokenSnapshot(for: context.provider)
            self.tokenErrors[context.provider.instanceID] = Self.tokenCostNoDataMessage(for: context.provider)
            self.tokenFailureGates[context.provider.instanceID]?.recordSuccess()
            return
        }
        self.logTokenUsageSuccess(
            provider: context.provider,
            snapshot: snapshot,
            historyDays: context.historyDays,
            startedAt: context.startedAt)
        self.publishTokenSnapshot(snapshot, for: context.provider)
        self.tokenErrors[context.provider.instanceID] = nil
        self.tokenFailureGates[context.provider.instanceID]?.recordSuccess()
        self.persistWidgetSnapshot(reason: "token-usage")
    }

    func resetTokenUsageState(for provider: UsageProvider) {
        self.clearTokenSnapshot(for: provider)
        self.clearSpendDashboardTokenSnapshot(for: provider)
        self.tokenErrors[provider.instanceID] = nil
        self.tokenFailureGates[provider.instanceID]?.reset()
        self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
        self.tokenFetchFailureCooldowns.removeValue(forKey: provider.instanceID)
        self.lastSpendDashboardTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastSpendDashboardTokenFetchScope.removeValue(forKey: provider.instanceID)
    }

    func clearTokenFetchMetadataIfMatching(
        provider: UsageProvider,
        attemptedAt: Date,
        costScopeSignature: String)
    {
        guard self.lastTokenFetchAt[provider.instanceID] == attemptedAt,
              self.lastTokenFetchScope[provider.instanceID] == costScopeSignature
        else {
            return
        }
        self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
        self.tokenFetchFailureCooldowns.removeValue(forKey: provider.instanceID)
    }

    /// Timeouts keep the normal cadence; forbidden cost requests wait hours rather than retrying every tick.
    nonisolated static func tokenFetchFailureRetryDelay(_ error: Error, ttl: TimeInterval?) -> TimeInterval? {
        switch error {
        case CostUsageError.timedOut: ttl
        default: nil
        }
    }
}
