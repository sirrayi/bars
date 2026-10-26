import CodexBarCore
import CryptoKit
import Foundation
import Observation

struct SpendDashboardConfiguration: Equatable, Sendable {
    let costUsageEnabled: Bool
    let preferredCurrencyCode: String
    let providerIDs: [String]
    let sourceOwnershipFingerprints: [String]
    let sourceRevisions: [String]
    let bucketTimeZoneIdentifier: String
    let hiddenSourceIDs: [String]
    let menuOwnershipFingerprint: String

    init(
        costUsageEnabled: Bool,
        preferredCurrencyCode: String = "auto",
        providerIDs: [String],
        sourceOwnershipFingerprints: [String] = [],
        sourceRevisions: [String] = [],
        bucketTimeZoneIdentifier: String = "",
        hiddenSourceIDs: [String] = [],
        menuOwnershipFingerprint: String = "")
    {
        self.costUsageEnabled = costUsageEnabled
        self.preferredCurrencyCode = preferredCurrencyCode
        self.providerIDs = providerIDs
        self.sourceOwnershipFingerprints = sourceOwnershipFingerprints
        self.sourceRevisions = sourceRevisions
        self.bucketTimeZoneIdentifier = bucketTimeZoneIdentifier
        self.hiddenSourceIDs = hiddenSourceIDs
        self.menuOwnershipFingerprint = menuOwnershipFingerprint
    }

    var bucketCalendar: Calendar {
        CostUsageBucketTimeZone.calendar(identifier: self.bucketTimeZoneIdentifier)
    }
}

enum SpendDashboardRequestBuildMode: Equatable, Sendable {
    case refreshMissing
    case forceRefresh
    case captureOnly

    var forcesLoader: Bool {
        self == .forceRefresh
    }

    func shouldRefresh(hasPublication: Bool) -> Bool {
        switch self {
        case .refreshMissing: !hasPublication
        case .forceRefresh: true
        case .captureOnly: false
        }
    }
}

struct SpendDashboardLoadRequest: Sendable {
    let configuration: SpendDashboardConfiguration
    let capturedInputs: [SpendDashboardModel.ProviderInput]
    let unavailableSourceIDs: Set<String>
    let confirmedEmptySourceIDs: Set<String>
    let now: Date
    let force: Bool
    let independentRefreshPending: Bool

    init(
        configuration: SpendDashboardConfiguration,
        capturedInputs: [SpendDashboardModel.ProviderInput],
        unavailableSourceIDs: Set<String>,
        confirmedEmptySourceIDs: Set<String> = [],
        now: Date,
        force: Bool,
        independentRefreshPending: Bool = false)
    {
        self.configuration = configuration
        self.capturedInputs = capturedInputs
        self.unavailableSourceIDs = unavailableSourceIDs
        self.confirmedEmptySourceIDs = confirmedEmptySourceIDs
        self.now = now
        self.force = force
        self.independentRefreshPending = independentRefreshPending
    }
}

struct SpendDashboardLoadResult: Sendable {
    let inputs: [SpendDashboardModel.ProviderInput]
    let failedSourceIDs: Set<String>
    let invalidatedSourceIDs: Set<String>

    init(
        inputs: [SpendDashboardModel.ProviderInput],
        failedSourceIDs: Set<String>,
        invalidatedSourceIDs: Set<String> = [])
    {
        self.inputs = inputs
        self.failedSourceIDs = failedSourceIDs
        self.invalidatedSourceIDs = invalidatedSourceIDs
    }

    var failedSourceCount: Int {
        self.failedSourceIDs.count
    }
}

enum SpendDashboardSource {
    static let activityDays = 365
    /// Scan available logs once; display periods and the activity heatmap project this history.
    static var scanDays: Int {
        CostReportingPeriod.allTime.days(now: Date())
    }

    @MainActor
    static func configuration(settings: SettingsStore, store: UsageStore) -> SpendDashboardConfiguration {
        store.discardSpendDashboardTokenPublicationsIfCostUsageDisabled()
        return self.configuration(
            settings: settings,
            store: store,
            providers: self.costCapableProviders(store: store))
    }

    @MainActor
    private static func configuration(
        settings: SettingsStore,
        store: UsageStore,
        providers: [UsageProvider]) -> SpendDashboardConfiguration
    {
        SpendDashboardConfiguration(
            costUsageEnabled: settings.costUsageEnabled,
            preferredCurrencyCode: settings.preferredCurrencyCode,
            providerIDs: providers.map(\.rawValue),
            sourceOwnershipFingerprints: self.sourceOwnershipFingerprints(
                providers: providers,
                settings: settings,
                store: store),
            sourceRevisions: self.sourceRevisions(providers: providers, store: store),
            bucketTimeZoneIdentifier: settings.costUsageBucketTimeZoneIdentifier,
            hiddenSourceIDs: settings.spendDashboardHiddenSourceIDs,
            menuOwnershipFingerprint: self.menuOwnershipFingerprint(settings: settings, providers: providers))
    }

    @MainActor
    static func makeRequest(
        settings: SettingsStore,
        store: UsageStore,
        mode: SpendDashboardRequestBuildMode,
        now: Date? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }) async -> SpendDashboardLoadRequest
    {
        store.discardSpendDashboardTokenPublicationsIfCostUsageDisabled()
        let initialProviders = self.costCapableProviders(store: store)
        guard settings.costUsageEnabled else {
            return SpendDashboardLoadRequest(
                configuration: self.configuration(settings: settings, store: store),
                capturedInputs: [],
                unavailableSourceIDs: [],
                now: now ?? nowProvider(),
                force: mode.forcesLoader)
        }

        let providerBaselines = initialProviders.map { provider in
            let captured = self.capturedTokenPublication(store: store, provider: provider)
            let shouldRefresh: Bool = if mode == .refreshMissing,
                                         UsageStore.usesSpendDashboardIndependentTokenSnapshot(provider)
            {
                store.spendDashboardTokenRefreshNeeded(for: provider)
            } else {
                mode.shouldRefresh(hasPublication: captured.publication != nil)
            }
            return (
                provider: provider,
                publicationRevision: captured.revision,
                trigger: store.spendDashboardTokenRefreshTrigger(for: provider),
                shouldRefresh: shouldRefresh)
        }
        let baselinesToRefresh = providerBaselines.filter(\.shouldRefresh)
        if !baselinesToRefresh.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for baseline in baselinesToRefresh {
                    group.addTask {
                        if UsageStore.tokenCostRequiresProviderSnapshot(baseline.provider) {
                            await store.refreshProvider(baseline.provider)
                        } else {
                            await store.refreshSpendDashboardTokenUsageNow(for: baseline.provider, force: true)
                        }
                    }
                }
            }
        }

        // A later provider refresh can suspend while an earlier provider publishes again.
        // Capture every provider only after all refresh work finishes so the request owns the
        // newest same-scope publication available at this boundary.
        let captureNow = now ?? nowProvider()
        let providers = self.costCapableProviders(store: store)
        let configuration = self.configuration(settings: settings, store: store, providers: providers)
        guard configuration.costUsageEnabled else {
            return SpendDashboardLoadRequest(
                configuration: configuration,
                capturedInputs: [],
                unavailableSourceIDs: [],
                now: captureNow,
                force: mode.forcesLoader)
        }

        var inputs: [SpendDashboardModel.ProviderInput] = []
        var unavailableSourceIDs: Set<String> = []
        var confirmedEmptySourceIDs: Set<String> = []
        for provider in providers {
            guard let baseline = providerBaselines.first(where: { $0.provider == provider }) else {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            let current = self.capturedTokenPublication(store: store, provider: provider)
            guard let currentPublication = current.publication else {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            if baseline.shouldRefresh, baseline.publicationRevision == current.revision {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            guard let snapshot = self.dashboardTokenSnapshot(
                store: store,
                provider: provider,
                publication: currentPublication)
            else {
                confirmedEmptySourceIDs.insert(provider.rawValue)
                continue
            }
            inputs.append(SpendDashboardModel.ProviderInput(
                provider: provider,
                displayName: store.metadata(for: provider).displayName,
                snapshot: snapshot))
        }
        return SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: inputs,
            unavailableSourceIDs: unavailableSourceIDs,
            confirmedEmptySourceIDs: confirmedEmptySourceIDs,
            now: captureNow,
            force: mode.forcesLoader,
            independentRefreshPending: providers.contains { provider in
                guard UsageStore.usesSpendDashboardIndependentTokenSnapshot(provider),
                      !store.spendDashboardTokenRefreshInFlight.contains(provider.instanceID),
                      store.spendDashboardTokenRefreshNeeded(for: provider)
                else { return false }
                // Capture barriers may discover pending work; refresh passes repeat only for triggers
                // that changed while suspended, never merely because a source remained unavailable.
                return mode == .captureOnly || providerBaselines.first { $0.provider == provider }?.trigger !=
                    store.spendDashboardTokenRefreshTrigger(for: provider)
            })
    }

    /// Every source is captured from store publications while the request is built; loading only
    /// reports which captured sources could not be refreshed.
    static func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: request.unavailableSourceIDs)
    }

    @MainActor
    static func costCapableProviders(store: UsageStore) -> [UsageProvider] {
        store.enabledFirstPartyProvidersForDisplay().filter {
            store.settings.isCostUsageEffectivelyEnabled(for: $0)
        }
    }

    @MainActor
    static func currentMenuOwnershipFingerprint(settings: SettingsStore, store: UsageStore) -> String {
        self.menuOwnershipFingerprint(settings: settings, providers: self.costCapableProviders(store: store))
    }

    @MainActor
    private static func menuOwnershipFingerprint(
        settings: SettingsStore,
        providers: [UsageProvider]) -> String
    {
        var parts = providers.map { provider in
            "\(provider.rawValue):\(settings.providerConfigRevision(for: provider))"
        }
        parts.append("bucket:\(settings.costUsageBucketTimeZoneIdentifier)")
        return self.sha256(parts.joined(separator: "\u{0}"))
    }

    @MainActor
    private static func sourceRevisions(
        providers: [UsageProvider],
        store: UsageStore) -> [String]
    {
        var revisions = providers.map { provider in
            let current: CurrentProviderConfigTokenPublication? =
                if UsageStore.usesSpendDashboardIndependentTokenSnapshot(provider) {
                    store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: provider)
                } else {
                    store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider)
                }
            guard let current else { return "\(provider.rawValue):unavailable" }
            guard let snapshot = current.snapshot else {
                return "\(provider.rawValue):empty:\(current.publicationRevision)"
            }
            return "\(provider.rawValue):snapshot:\(current.publicationRevision):\(self.snapshotRevision(snapshot))"
        }
        for provider in providers where UsageStore.usesSpendDashboardIndependentTokenSnapshot(provider) {
            let trigger = store.spendDashboardTokenRefreshTrigger(for: provider)
            let inFlight = store.spendDashboardTokenRefreshInFlight.contains(provider.instanceID)
            // Keep refresh triggers outside the source's data-revision prefix used by forced reconciliation.
            revisions
                .append("independent-trigger-\(provider.rawValue):\(trigger.regularPublicationRevision):\(inFlight)")
        }
        return revisions
    }

    private static func snapshotRevision(_ snapshot: CostUsageTokenSnapshot) -> String {
        var encoder = SpendDashboardSnapshotRevisionEncoder()
        encoder.append(snapshot.currencyCode)
        encoder.append(snapshot.historyDays)
        encoder.append(snapshot.historyCoverageIsEstablished)
        encoder.append(snapshot.detailsAreComplete)
        encoder.append(snapshot.updatedAt.timeIntervalSinceReferenceDate)
        encoder.append(snapshot.last30DaysTokens)
        encoder.append(snapshot.last30DaysCostUSD)
        encoder.append(snapshot.last30DaysRequests)
        encoder.append(snapshot.daily.count)
        for entry in snapshot.daily {
            encoder.append(entry.date)
            encoder.append(entry.inputTokens)
            encoder.append(entry.cacheReadTokens)
            encoder.append(entry.cacheCreationTokens)
            encoder.append(entry.outputTokens)
            encoder.append(entry.totalTokens)
            encoder.append(entry.requestCount)
            encoder.append(entry.costUSD)
            encoder.append(entry.modelBreakdowns?.count)
            for breakdown in entry.modelBreakdowns ?? [] {
                encoder.append(breakdown.modelName)
                encoder.append(breakdown.incompleteRequestCount)
                encoder.append(breakdown.totalTokens)
                encoder.append(breakdown.requestCount)
                encoder.append(breakdown.costUSD)
                encoder.append(breakdown.standardCostUSD)
                encoder.append(breakdown.priorityCostUSD)
                encoder.append(breakdown.standardTokens)
                encoder.append(breakdown.priorityTokens)
            }
        }
        encoder.append(snapshot.hourly.count)
        for entry in snapshot.hourly {
            encoder.append(entry.hour.timeIntervalSinceReferenceDate)
            encoder.append(entry.totalTokens)
            encoder.append(entry.costUSD)
        }
        return encoder.finalize()
    }

    @MainActor
    private static func sourceOwnershipFingerprints(
        providers: [UsageProvider],
        settings: SettingsStore,
        store: UsageStore) -> [String]
    {
        providers.map { provider in
            var config = (settings.providerConfig(for: provider) ?? ProviderConfig(id: provider.instanceID))
                .fetchIdentityConfig
            config.enabled = nil
            config.quotaWarnings = nil
            // The dashboard follows the effective account, not the whole saved-account collection.
            // Inactive-account edits must not invalidate visible spend for the selected account.
            config.tokenAccounts = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = (try? encoder.encode(config)) ?? Data()
            let scope = UsageStore.usesSpendDashboardIndependentTokenSnapshot(provider)
                ? store.spendDashboardTokenSnapshotScopeSignature(for: provider)
                : store.tokenSnapshotScopeSignature(for: provider)
            let accountOwnership = settings.effectiveSelectedTokenAccount(for: provider)
                .map { store.tokenAccountSnapshotCacheKey(provider: provider, account: $0) }
                ?? "ambient"
            return "\(provider.rawValue):\(self.sha256(encoded)):\(self.sha256(scope)):" +
                self.sha256("\(accountOwnership)\u{0}\(settings.costUsageBucketTimeZoneIdentifier)")
        }
    }

    @MainActor
    private static func dashboardTokenSnapshot(
        store: UsageStore,
        provider: UsageProvider,
        publication: CurrentProviderConfigTokenPublication) -> CostUsageTokenSnapshot?
    {
        if UsageStore.tokenCostRequiresProviderSnapshot(provider),
           let usage = store.snapshot(for: provider.instanceID),
           let derived = store.tokenSnapshot(
               fromProviderSnapshot: usage,
               provider: provider,
               historyDays: scanDays)
        {
            return derived
        }
        return publication.snapshot
    }

    @MainActor
    private static func capturedTokenPublication(
        store: UsageStore,
        provider: UsageProvider) -> (
        publication: CurrentProviderConfigTokenPublication?,
        revision: UInt64)
    {
        if UsageStore.usesSpendDashboardIndependentTokenSnapshot(provider) {
            let revision = store.spendDashboardTokenSnapshotPublicationRevision(for: provider)
            return (store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: provider), revision)
        }
        return (
            store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider),
            store.tokenSnapshotPublicationRevision(for: provider))
    }

    private static func sha256(_ value: String) -> String {
        self.sha256(Data(value.utf8))
    }

    private static func sha256(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}

private struct SpendDashboardSnapshotRevisionEncoder {
    private var hasher = SHA256()

    mutating func append(_ value: String) {
        let data = Data(value.utf8)
        self.append(UInt64(data.count))
        self.hasher.update(data: data)
    }

    mutating func append(_ value: Int) {
        self.append(UInt64(bitPattern: Int64(value)))
    }

    mutating func append(_ value: Int?) {
        guard let value else {
            self.appendPresence(false)
            return
        }
        self.appendPresence(true)
        self.append(value)
    }

    mutating func append(_ value: Bool) {
        self.appendPresence(value)
    }

    mutating func append(_ value: Double) {
        self.append(value.bitPattern)
    }

    mutating func append(_ value: Double?) {
        guard let value else {
            self.appendPresence(false)
            return
        }
        self.appendPresence(true)
        self.append(value)
    }

    mutating func finalize() -> String {
        self.hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func appendPresence(_ isPresent: Bool) {
        var byte: UInt8 = isPresent ? 1 : 0
        withUnsafeBytes(of: &byte) { bytes in
            self.hasher.update(data: Data(bytes))
        }
    }

    private mutating func append(_ value: UInt64) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { bytes in
            self.hasher.update(data: Data(bytes))
        }
    }
}

@MainActor
@Observable
final class SpendDashboardController {
    typealias RequestBuilder = @MainActor @Sendable (SpendDashboardRequestBuildMode) async
        -> SpendDashboardLoadRequest
    typealias Loader = @Sendable (SpendDashboardLoadRequest) async -> SpendDashboardLoadResult
    typealias PublicationHandler = @MainActor @Sendable (SpendDashboardPublication) -> Void

    private enum ReconciliationObservation: Sendable {
        case confirmedEmpty
        case confirmedNonempty(SpendDashboardModel.ProviderInput)
    }

    private struct ForcedOutcome: Sendable {
        let request: SpendDashboardLoadRequest
        let result: SpendDashboardLoadResult
        let invalidatedSourceIDs: Set<String>
        let observations: [String: ReconciliationObservation]

        func incorporating(capture: SpendDashboardLoadRequest) -> Self {
            var observations = self.observations
            for input in capture.capturedInputs {
                let forcedRevision = Self.sourceRevision(for: input.id, in: self.request.configuration)
                let captureRevision = Self.sourceRevision(for: input.id, in: capture.configuration)
                let hasNewerSourceRevision = forcedRevision != nil
                    && captureRevision != nil
                    && forcedRevision != captureRevision
                if self.result.failedSourceIDs.contains(input.id),
                   observations[input.id] == nil,
                   !hasNewerSourceRevision
                {
                    continue
                }
                observations[input.id] = .confirmedNonempty(input)
            }
            for sourceID in capture.confirmedEmptySourceIDs {
                observations[sourceID] = .confirmedEmpty
            }
            return Self(
                request: self.request,
                result: self.result,
                invalidatedSourceIDs: self.invalidatedSourceIDs,
                observations: observations)
        }

        private static func sourceRevision(
            for sourceID: String,
            in configuration: SpendDashboardConfiguration) -> String?
        {
            let prefix = "\(sourceID):"
            return configuration.sourceRevisions.first { $0.hasPrefix(prefix) }
        }

        var confirmedEmptySourceIDs: Set<String> {
            Set(self.observations.compactMap { sourceID, observation in
                guard case .confirmedEmpty = observation else { return nil }
                return sourceID
            })
        }

        var confirmedNonemptyInputs: [SpendDashboardModel.ProviderInput] {
            self.observations.sorted { $0.key < $1.key }.compactMap { _, observation in
                guard case let .confirmedNonempty(input) = observation else { return nil }
                return input
            }
        }
    }

    private struct ReconciledOutcome: Sendable {
        let result: SpendDashboardLoadResult
        let confirmedEmptySourceIDs: Set<String>
    }

    private enum LoadPhase: Sendable {
        case ordinary
        case forcing
        case reconciling(ForcedOutcome)

        var buildMode: SpendDashboardRequestBuildMode {
            switch self {
            case .ordinary: .refreshMissing
            case .forcing: .forceRefresh
            case .reconciling: .captureOnly
            }
        }

        var manualRefreshOutstanding: Bool {
            switch self {
            case .ordinary: false
            case .forcing, .reconciling: true
            }
        }
    }

    private(set) var model = SpendDashboardModel(requestedDays: 30, groups: [])
    private(set) var publication = SpendDashboardPublication.empty
    private(set) var isRefreshing = false
    private(set) var failedSourceCount = 0
    private(set) var generation: UInt64 = 0
    private(set) var configuration: SpendDashboardConfiguration?
    private(set) var selectedPeriod: CostReportingPeriod
    private(set) var selectedDay: Date?

    private static let periodDefaultsKey = "settingsSpendDashboardPeriod"
    private let userDefaults: UserDefaults
    private let requestBuilder: RequestBuilder
    private let loader: Loader
    private let nowProvider: @Sendable () -> Date
    private let publicationHandler: PublicationHandler?
    private var loadTask: Task<Void, Never>?
    private var loadedInputs: [SpendDashboardModel.ProviderInput] = []
    private var loadedInputScopes: [String: SpendDashboardLoadedInputScope] = [:]
    private var loadedAt = Date()
    private var lastSuccessfulConfiguration: SpendDashboardConfiguration?
    private var phase = LoadPhase.ordinary
    // Throttle high-frequency date-window refreshes (didBecomeActive bursts).
    private var lastRefreshDateWindowAt: Date?
    private var lastRefreshDateWindowDayStart: Date?
    private static let dashboardSnapshotTTL: TimeInterval = 5 * 60
    private(set) var dashboardSnapshotLoadedAt: Date?

    init(
        userDefaults: UserDefaults = .standard,
        requestBuilder: @escaping RequestBuilder,
        loader: @escaping Loader = SpendDashboardSource.load,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        publicationHandler: PublicationHandler? = nil)
    {
        self.userDefaults = userDefaults
        self.requestBuilder = requestBuilder
        self.loader = loader
        self.nowProvider = nowProvider
        self.publicationHandler = publicationHandler
        let legacyDays = userDefaults.object(forKey: "settingsSpendDashboardDays") as? Int
        self.selectedPeriod = userDefaults.string(forKey: Self.periodDefaultsKey)
            .flatMap(CostReportingPeriod.init(rawValue:))
            ?? (legacyDays == 365 ? .allTime : CostReportingPeriod.migrated(
                rawValue: legacyDays == nil ? userDefaults.string(forKey: CostReportingPeriod.defaultsKey) : nil,
                legacyDays: legacyDays))
    }

    func update(configuration: SpendDashboardConfiguration, force: Bool = false) {
        if force {
            self.configuration = configuration
            self.startLoad(configuration: configuration, phase: .forcing)
            return
        }
        guard configuration != self.configuration else { return }
        let previousConfiguration = self.configuration
        // Fast-path: display-only changes (filter, currency, hide flag) require
        // only a model rebuild — no token capture.
        if let previousConfiguration,
           Self.isDisplayOnlyConfigurationChange(from: previousConfiguration, to: configuration)
        {
            self.configuration = configuration
            // Provider-specific by design: bucket calendar change renormalizes selected day atomically with new config.
            if let selectedDay = self.selectedDay {
                let newCalendar = CostUsageBucketTimeZone.calendar(identifier: configuration.bucketTimeZoneIdentifier)
                let normalized = newCalendar.startOfDay(for: selectedDay)
                if normalized != selectedDay {
                    self.selectedDay = normalized
                }
            }
            self.rebuildModel()
            return
        }
        self.configuration = configuration
        // Normalize selected day when bucket timezone changes, atomically with new configuration.
        if let selectedDay = self.selectedDay,
           previousConfiguration?.bucketTimeZoneIdentifier != configuration.bucketTimeZoneIdentifier
        {
            let newCalendar = CostUsageBucketTimeZone.calendar(identifier: configuration.bucketTimeZoneIdentifier)
            let normalized = newCalendar.startOfDay(for: selectedDay)
            if normalized != selectedDay {
                self.selectedDay = normalized
            }
        }
        if self.isRefreshing || self.phase.manualRefreshOutstanding,
           let previousConfiguration,
           Self.sameSourceOwnership(previousConfiguration, configuration)
        {
            // Same-owner revision churn during an in-flight load adopts the newer
            // configuration and lets the current pass finish once; handleBuiltRequest
            // reconciles any remaining drift after apply.
            self.publishCurrentState()
            return
        }
        let nextPhase: LoadPhase = self.phase.manualRefreshOutstanding ? .forcing : .ordinary
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    private func startLoad(
        configuration: SpendDashboardConfiguration,
        phase: LoadPhase)
    {
        self.generation &+= 1
        let generation = self.generation
        self.loadTask?.cancel()
        let invalidatedSourceIDs = switch phase {
        case let .reconciling(outcome): outcome.invalidatedSourceIDs
        case .ordinary, .forcing:
            Self.invalidatedSourceIDs(
                previous: self.lastSuccessfulConfiguration,
                current: configuration)
        }
        self.phase = phase

        if !invalidatedSourceIDs.isEmpty {
            self.loadedInputs.removeAll { invalidatedSourceIDs.contains($0.id) }
            self.failedSourceIDs.subtract(invalidatedSourceIDs)
            self.confirmedEmptySourceIDs.subtract(invalidatedSourceIDs)
            for sourceID in invalidatedSourceIDs {
                self.loadedInputScopes.removeValue(forKey: sourceID)
            }
            self.failedSourceCount = 0
            self.rebuildModel()
        }
        guard configuration.costUsageEnabled, !configuration.providerIDs.isEmpty else {
            self.loadedInputs = []
            self.loadedInputScopes = [:]
            self.failedSourceIDs = []
            self.confirmedEmptySourceIDs = []
            self.failedSourceCount = 0
            self.isRefreshing = false
            self.lastSuccessfulConfiguration = configuration
            self.phase = .ordinary
            self.loadTask = nil
            self.rebuildModel()
            return
        }

        self.isRefreshing = true
        self.publishCurrentState()
        self.loadTask = Task { [weak self] in
            guard let self else { return }
            let request = await self.requestBuilder(phase.buildMode)
            guard !Task.isCancelled,
                  generation == self.generation
            else { return }
            await self.handleBuiltRequest(
                request,
                startedWith: configuration,
                phase: phase,
                generation: generation,
                invalidatedSourceIDs: invalidatedSourceIDs)
        }
    }

    private func handleBuiltRequest(
        _ request: SpendDashboardLoadRequest,
        startedWith startConfiguration: SpendDashboardConfiguration,
        phase: LoadPhase,
        generation: UInt64,
        invalidatedSourceIDs: Set<String>) async
    {
        guard let targetConfiguration = self.configuration else { return }
        if case let .reconciling(outcome) = phase,
           !Self.sameSourceOwnership(outcome.request.configuration, targetConfiguration)
        {
            self.startLoad(configuration: targetConfiguration, phase: .forcing)
            return
        }
        guard Self.sameSourceOwnership(startConfiguration, targetConfiguration) else {
            self.restartAfterBuildMismatch(targetConfiguration, phase: phase)
            return
        }

        let phase: LoadPhase = if case let .reconciling(outcome) = phase,
                                  Self.sameSourceOwnership(request.configuration, targetConfiguration)
        {
            .reconciling(outcome.incorporating(capture: request))
        } else {
            phase
        }

        if request.configuration != targetConfiguration {
            if case .forcing = phase,
               Self.sameSourceOwnership(request.configuration, targetConfiguration)
            {
                // Same-owner revision churn does not justify another provider force. The forced
                // loader executes once; its mandatory capture barrier reconciles the latest token.
                if targetConfiguration == startConfiguration {
                    self.configuration = request.configuration
                }
            } else if targetConfiguration == startConfiguration,
                      Self.sameSourceOwnership(targetConfiguration, request.configuration)
            {
                // The request owns an atomic newer same-owner capture. Adopt it even when the
                // external observation callback has not delivered that revision yet.
                self.configuration = request.configuration
            } else {
                let nextConfiguration = targetConfiguration == startConfiguration
                    ? request.configuration
                    : targetConfiguration
                self.restartAfterBuildMismatch(nextConfiguration, phase: phase)
                return
            }
        }

        switch phase {
        case .ordinary:
            let result = await self.loader(request)
            guard !Task.isCancelled,
                  generation == self.generation,
                  let latestConfiguration = self.configuration
            else { return }
            guard request.configuration == latestConfiguration else {
                self.startLoad(configuration: latestConfiguration, phase: .ordinary)
                return
            }
            self.apply(
                request: request,
                result: result,
                invalidatedSourceIDs: invalidatedSourceIDs,
                confirmedEmptySourceIDs: request.confirmedEmptySourceIDs)

        case .forcing:
            let result = await self.loader(request)
            guard !Task.isCancelled,
                  generation == self.generation,
                  let latestConfiguration = self.configuration
            else { return }
            guard Self.sameSourceOwnership(request.configuration, latestConfiguration) else {
                self.startLoad(configuration: latestConfiguration, phase: .forcing)
                return
            }
            let outcome = ForcedOutcome(
                request: request,
                result: result,
                invalidatedSourceIDs: invalidatedSourceIDs,
                observations: Dictionary(uniqueKeysWithValues: request.confirmedEmptySourceIDs.map {
                    ($0, ReconciliationObservation.confirmedEmpty)
                }))
            self.startLoad(configuration: latestConfiguration, phase: .reconciling(outcome))
            return

        case let .reconciling(outcome):
            let reconciled = Self.merge(outcome: outcome, capture: request)
            self.apply(
                request: request,
                result: reconciled.result,
                invalidatedSourceIDs: outcome.invalidatedSourceIDs,
                confirmedEmptySourceIDs: reconciled.confirmedEmptySourceIDs)
        }
        // Configuration is captured after suspended scans. A newer regular publication in that
        // capture still needs one ordinary follow-up; it was not incorporated by the completed scan.
        if request.independentRefreshPending, let configuration = self.configuration {
            self.startLoad(configuration: configuration, phase: .ordinary)
        }
    }

    private func restartAfterBuildMismatch(
        _ configuration: SpendDashboardConfiguration,
        phase: LoadPhase)
    {
        self.configuration = configuration
        let nextPhase: LoadPhase = switch phase {
        case .ordinary: .ordinary
        case .forcing: .forcing
        case let .reconciling(outcome):
            Self.sameSourceOwnership(outcome.request.configuration, configuration)
                ? .reconciling(outcome)
                : .forcing
        }
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    private func apply(
        request: SpendDashboardLoadRequest,
        result: SpendDashboardLoadResult,
        invalidatedSourceIDs: Set<String>,
        confirmedEmptySourceIDs: Set<String>)
    {
        var nextInputs = result.inputs
        var nextInputScopes = Dictionary(uniqueKeysWithValues: nextInputs.map { input in
            (input.id, SpendDashboardLoadedInputScope(configuration: request.configuration, input: input))
        })
        let unsafeSourceIDs = invalidatedSourceIDs
            .union(result.invalidatedSourceIDs)
            .union(confirmedEmptySourceIDs)
        if !result.failedSourceIDs.isEmpty {
            let freshIDs = Set(nextInputs.map(\.id))
            let retainedInputs = self.loadedInputs.filter {
                result.failedSourceIDs.contains($0.id) &&
                    !unsafeSourceIDs.contains($0.id) &&
                    self.loadedInputScopes[$0.id] == SpendDashboardLoadedInputScope(
                        configuration: request.configuration, input: $0) &&
                    !freshIDs.contains($0.id)
            }
            nextInputs.append(contentsOf: retainedInputs)
            for input in retainedInputs {
                nextInputScopes[input.id] = self.loadedInputScopes[input.id]
            }
        }
        self.configuration = request.configuration
        self.loadedInputs = Self.stableUniqueInputs(nextInputs)
        self.loadedInputScopes = nextInputScopes
        self.loadedAt = request.now
        self.dashboardSnapshotLoadedAt = self.nowProvider()
        self.lastSuccessfulConfiguration = request.configuration
        self.failedSourceCount = result.failedSourceCount
        self.failedSourceIDs = result.failedSourceIDs
        self.confirmedEmptySourceIDs = confirmedEmptySourceIDs
        self.isRefreshing = false
        self.phase = .ordinary
        self.loadTask = nil
        self.rebuildModel()
    }

    private static func merge(
        outcome: ForcedOutcome,
        capture: SpendDashboardLoadRequest) -> ReconciledOutcome
    {
        let forceFailed = outcome.result.failedSourceIDs
        let invalidated = outcome.result.invalidatedSourceIDs
        let barrierFailed = capture.unavailableSourceIDs
        let confirmedNonemptyInputs = outcome.confirmedNonemptyInputs
        let confirmedNonemptyIDs = Set(confirmedNonemptyInputs.map(\.id))
        var inputs = capture.capturedInputs.filter {
            (!forceFailed.contains($0.id) || confirmedNonemptyIDs.contains($0.id)) &&
                !invalidated.contains($0.id) &&
                !outcome.confirmedEmptySourceIDs.contains($0.id)
        }
        var capturedIDs = Set(inputs.map(\.id))
        for input in confirmedNonemptyInputs
            where !capturedIDs.contains(input.id) && !invalidated.contains(input.id)
        {
            inputs.append(input)
            capturedIDs.insert(input.id)
        }
        for input in outcome.result.inputs
            where !capturedIDs.contains(input.id) &&
            !forceFailed.contains(input.id) &&
            !invalidated.contains(input.id) &&
            !outcome.confirmedEmptySourceIDs.contains(input.id) &&
            barrierFailed.contains(input.id)
        {
            inputs.append(input)
            capturedIDs.insert(input.id)
        }
        return ReconciledOutcome(
            result: SpendDashboardLoadResult(
                inputs: inputs,
                failedSourceIDs: forceFailed.union(barrierFailed),
                invalidatedSourceIDs: invalidated),
            confirmedEmptySourceIDs: outcome.confirmedEmptySourceIDs)
    }

    func refresh() {
        guard let configuration else { return }
        self.update(configuration: configuration, force: true)
    }

    func refreshIfStale(now: Date? = nil) {
        guard let configuration,
              !self.isRefreshing,
              !self.phase.manualRefreshOutstanding
        else { return }
        let now = now ?? self.nowProvider()
        if let loadedAt = self.dashboardSnapshotLoadedAt,
           self.failedSourceCount == 0,
           configuration.bucketCalendar.isDate(self.loadedAt, inSameDayAs: now),
           now.timeIntervalSince(loadedAt) >= 0,
           now.timeIntervalSince(loadedAt) < Self.dashboardSnapshotTTL
        {
            return
        }
        self.startLoad(configuration: configuration, phase: .ordinary)
    }

    func selectPeriod(_ period: CostReportingPeriod) {
        guard period != self.selectedPeriod else { return }
        self.selectedPeriod = period
        self.userDefaults.set(period.rawValue, forKey: Self.periodDefaultsKey)
        self.rebuildModel(publish: false)
    }

    func selectDay(_ day: Date?) {
        let calendar = self.configuration?.bucketCalendar ?? .current
        let normalized = day.map { calendar.startOfDay(for: $0) }
        guard normalized != self.selectedDay else { return }
        self.selectedDay = normalized
        self.rebuildModel(publish: false)
    }

    func refreshDateWindow(now: Date? = nil) {
        let now = now ?? self.nowProvider()
        let calendar = self.configuration?.bucketCalendar ?? .current
        let previousDay = calendar.startOfDay(for: self.loadedAt)
        let nextDay = calendar.startOfDay(for: now)
        let isSameDay = previousDay == nextDay
        // Throttle burst activations (didBecomeActive) that otherwise rebuild
        // the 365-day model on every app focus. Keep a 30s floor for same-day
        // revisits while still allowing immediate refresh when the bucket day
        // actually rolled over or a previous load failed.
        if isSameDay,
           let lastAt = self.lastRefreshDateWindowAt,
           let lastDay = self.lastRefreshDateWindowDayStart,
           lastDay == nextDay,
           now.timeIntervalSince(lastAt) < 30,
           self.lastSuccessfulConfiguration != nil,
           self.failedSourceCount == 0
        {
            self.loadedAt = now
            return
        }
        self.lastRefreshDateWindowAt = now
        self.lastRefreshDateWindowDayStart = nextDay
        self.loadedAt = now
        self.rebuildModel()
        guard let configuration else { return }
        guard !isSameDay || self.lastSuccessfulConfiguration == nil || self.failedSourceCount > 0
        else { return }
        let nextPhase: LoadPhase = self.phase.manualRefreshOutstanding ? .forcing : .ordinary
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    func stop() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.configuration = nil
        self.loadedInputs = []
        self.failedSourceIDs = []
        self.confirmedEmptySourceIDs = []
        self.isRefreshing = false
        self.phase = .ordinary
        self.lastRefreshDateWindowAt = nil
        self.lastRefreshDateWindowDayStart = nil
        self.dashboardSnapshotLoadedAt = nil
        self.publishCurrentState()
    }

    private func rebuildModel(publish: Bool = true) {
        let configuration = self.configuration
        self.model = SpendDashboardModel.build(
            inputs: self.loadedInputs,
            reportingPeriod: self.selectedPeriod,
            now: self.loadedAt,
            calendar: configuration?.bucketCalendar ?? .current,
            preferredCurrencyCode: configuration?.preferredCurrencyCode ?? "auto",
            hiddenSourceIDs: Set(configuration?.hiddenSourceIDs ?? []),
            selectedDay: self.selectedDay)
        if publish {
            self.publishCurrentState()
        }
    }

    @ObservationIgnored private var failedSourceIDs: Set<String> = []
    @ObservationIgnored private var confirmedEmptySourceIDs: Set<String> = []
    @ObservationIgnored private var publicationRevision: UInt64 = 0

    private func publishCurrentState() {
        self.publicationRevision &+= 1
        let inputByID = Dictionary(uniqueKeysWithValues: self.loadedInputs.map { ($0.id, $0) })
        let sourceIDs = self.orderedSourceIDs(inputByID: inputByID)
        let sources = sourceIDs.compactMap { sourceID -> SpendSourcePublication? in
            let input = inputByID[sourceID]
            guard let provider = input?.provider ?? UsageProvider(rawValue: sourceID) else { return nil }
            let state: SpendSourcePublication.State = if input != nil {
                self.failedSourceIDs.contains(sourceID) ? .staleLastKnown : .available
            } else if self.confirmedEmptySourceIDs.contains(sourceID) {
                .confirmedEmpty
            } else if self.isRefreshing {
                .loading
            } else {
                .unavailable
            }
            return SpendSourcePublication(
                id: sourceID,
                provider: provider,
                displayName: input?.displayName ?? ProviderDescriptorRegistry.descriptor(for: provider).metadata
                    .displayName,
                state: state)
        }
        let publication = SpendDashboardPublication(
            revision: self.publicationRevision,
            generation: self.generation,
            configuration: self.configuration,
            loadedAt: self.loadedAt,
            isRefreshing: self.isRefreshing,
            inputs: self.loadedInputs,
            sources: sources)
        self.publication = publication
        self.publicationHandler?(publication)
    }

    private static func stableUniqueInputs(
        _ inputs: [SpendDashboardModel.ProviderInput]) -> [SpendDashboardModel.ProviderInput]
    {
        var seen: Set<String> = []
        return inputs.filter { seen.insert($0.id).inserted }
    }

    private func orderedSourceIDs(
        inputByID: [String: SpendDashboardModel.ProviderInput]) -> [String]
    {
        var ids: [String] = []
        ids.append(contentsOf: self.configuration?.providerIDs ?? [])
        ids.append(contentsOf: inputByID.keys.sorted())
        ids.append(contentsOf: self.confirmedEmptySourceIDs.sorted())
        ids.append(contentsOf: self.failedSourceIDs.sorted())
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }

    private static func sameSourceOwnership(
        _ lhs: SpendDashboardConfiguration,
        _ rhs: SpendDashboardConfiguration) -> Bool
    {
        lhs.costUsageEnabled == rhs.costUsageEnabled &&
            lhs.providerIDs == rhs.providerIDs &&
            lhs.sourceOwnershipFingerprints == rhs.sourceOwnershipFingerprints &&
            lhs.bucketTimeZoneIdentifier == rhs.bucketTimeZoneIdentifier &&
            lhs.hiddenSourceIDs == rhs.hiddenSourceIDs &&
            lhs.preferredCurrencyCode == rhs.preferredCurrencyCode
    }

    private static func isDisplayOnlyConfigurationChange(
        from lhs: SpendDashboardConfiguration,
        to rhs: SpendDashboardConfiguration) -> Bool
    {
        // Only presentation-layer fields changed; no provider scan or token capture needed.
        guard lhs.costUsageEnabled == rhs.costUsageEnabled,
              lhs.providerIDs == rhs.providerIDs,
              lhs.sourceOwnershipFingerprints == rhs.sourceOwnershipFingerprints,
              lhs.sourceRevisions == rhs.sourceRevisions,
              lhs.bucketTimeZoneIdentifier == rhs.bucketTimeZoneIdentifier
        else { return false }
        return lhs.hiddenSourceIDs != rhs.hiddenSourceIDs ||
            lhs.preferredCurrencyCode != rhs.preferredCurrencyCode ||
            lhs.menuOwnershipFingerprint != rhs.menuOwnershipFingerprint
    }

    private static func invalidatedSourceIDs(
        previous: SpendDashboardConfiguration?,
        current: SpendDashboardConfiguration) -> Set<String>
    {
        guard let previous else { return [] }
        let previousOwnership = self.sourceOwnershipByID(previous.sourceOwnershipFingerprints)
        let currentOwnership = self.sourceOwnershipByID(current.sourceOwnershipFingerprints)
        let providerIDs = Set(previousOwnership.keys).union(currentOwnership.keys)
        return Set(providerIDs.filter { previousOwnership[$0] != currentOwnership[$0] })
    }

    private static func sourceOwnershipByID(_ fingerprints: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fingerprints.compactMap { fingerprint in
            guard let separator = fingerprint.firstIndex(of: ":") else { return nil }
            let sourceID = String(fingerprint[..<separator])
            guard !sourceID.isEmpty else { return nil }
            return (sourceID, fingerprint)
        })
    }
}
