import Foundation

public enum CostUsageError: LocalizedError, Sendable {
    case unsupportedProvider(UsageProvider)
    case timedOut(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider):
            return "Cost summary is not supported for \(provider.rawValue)."
        case let .timedOut(seconds):
            if seconds >= 60, seconds % 60 == 0 {
                return "Cost refresh timed out after \(seconds / 60)m."
            }
            return "Cost refresh timed out after \(seconds)s."
        }
    }
}

public struct CostUsageFetcher: Sendable {
    private let scannerOptions: CostUsageScanner.Options?

    public init(cacheRoot: URL? = nil, calendar: Calendar? = nil) {
        self.scannerOptions = cacheRoot == nil && calendar == nil
            ? nil : CostUsageScanner.Options(cacheRoot: cacheRoot, calendar: calendar ?? .current)
    }

    init(scannerOptions: CostUsageScanner.Options) {
        self.scannerOptions = scannerOptions
    }

    public func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        historyDays: Int = 30,
        allowPricingRefresh: Bool = true,
        refreshPricingInBackground: Bool = true,
        bypassScannerDebounce: Bool = false,
        calendar: Calendar? = nil) async throws -> CostUsageTokenSnapshot
    {
        try await Self.loadTokenSnapshot(
            provider: provider,
            environment: environment,
            now: now,
            forceRefresh: forceRefresh,
            historyDays: historyDays,
            allowPricingRefresh: allowPricingRefresh,
            refreshPricingInBackground: refreshPricingInBackground,
            bypassScannerDebounce: bypassScannerDebounce,
            scannerOptions: self.scannerOptions(calendar: calendar))
    }

    package func loadTokenResult(
        provider: UsageProvider,
        claudeConfigDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        historyDays: Int = 30,
        allowPricingRefresh: Bool = true,
        refreshPricingInBackground: Bool = true,
        bypassScannerDebounce: Bool,
        calendar: Calendar? = nil,
        reportContext: CostUsageReportContext = .regular) async throws -> CostUsageTokenResult
    {
        var options = self.scannerOptions(calendar: calendar)
        // Provider-specific by design: explicit account roots never include ambient or swap history.
        if provider == .claude, let claudeConfigDirectory {
            let roots = ClaudeConfigPaths.costProjectsRoots(
                accountConfigDirectory: claudeConfigDirectory, environment: environment)
            guard let root = roots.first, FileManager.default.isReadableFile(atPath: root.path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            options = options ?? CostUsageScanner.Options()
            options?.claudeProjectsRoots = roots
        }
        return try await Self.loadTokenResult(
            provider: provider,
            environment: environment,
            now: now,
            forceRefresh: forceRefresh,
            historyDays: historyDays,
            allowPricingRefresh: allowPricingRefresh,
            refreshPricingInBackground: refreshPricingInBackground,
            bypassScannerDebounce: bypassScannerDebounce,
            scannerOptions: options,
            reportContext: reportContext)
    }

    private func scannerOptions(calendar: Calendar?) -> CostUsageScanner.Options? {
        guard calendar != nil || self.scannerOptions != nil else { return self.scannerOptions }
        var options = self.scannerOptions ?? CostUsageScanner.Options()
        if let calendar {
            options.calendar = calendar
        }
        return options
    }

    static func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        historyDays: Int = 30,
        allowPricingRefresh: Bool = true,
        refreshPricingInBackground: Bool = true,
        bypassScannerDebounce: Bool = false,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil,
        modelsDevClient: ModelsDevClient = ModelsDevClient(),
        retryUnknownPricing: Bool = true) async throws -> CostUsageTokenSnapshot
    {
        try await self.loadTokenResult(
            provider: provider,
            environment: environment,
            now: now,
            forceRefresh: forceRefresh,
            historyDays: historyDays,
            allowPricingRefresh: allowPricingRefresh,
            refreshPricingInBackground: refreshPricingInBackground,
            bypassScannerDebounce: bypassScannerDebounce,
            scannerOptions: overrideScannerOptions,
            modelsDevClient: modelsDevClient,
            retryUnknownPricing: retryUnknownPricing).snapshot
    }

    static func loadTokenResult(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        historyDays: Int = 30,
        allowPricingRefresh: Bool = true,
        refreshPricingInBackground: Bool = true,
        bypassScannerDebounce: Bool = false,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil,
        modelsDevClient: ModelsDevClient = ModelsDevClient(),
        retryUnknownPricing: Bool = true,
        reportContext: CostUsageReportContext? = nil) async throws -> CostUsageTokenResult
    {
        guard self.supportsTokenSnapshot(provider) else {
            throw CostUsageError.unsupportedProvider(provider)
        }

        let clampedHistoryDays = max(1, historyDays)
        var options = overrideScannerOptions ?? CostUsageScanner.Options()
        // OpenCode Go reads Console-metered history when the workspace API key is available, then falls
        // back to its device-local reader and recorded-cost projection.
        if provider == .opencodego {
            let calendar = options.calendar
            if let metered = await Self.meteredOpenCodeGoUsage(
                environment: environment,
                now: now,
                historyDays: clampedHistoryDays,
                calendar: calendar)
            {
                return metered
            }
            let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            return try await CostUsageScanExecutor.run { _ in
                let usage = try OpenCodeGoLocalUsageReader(homeDirectory: home).fetch(
                    now: now, historyDays: clampedHistoryDays, calendar: calendar)
                return CostUsageTokenResult(snapshot: usage.toCostUsageTokenSnapshot(
                    historyDays: clampedHistoryDays, calendar: calendar))
            }
        }
        // Provider-specific by design: Devin reads the Devin CLI's local session ledger; SWE-2
        // requests are free during the promo and Claude-routed requests price like Claude.
        if provider == .devin {
            return try await CostUsageTokenResult(snapshot: Self.loadDevinLocalSnapshot(
                environment: environment,
                now: now,
                historyDays: clampedHistoryDays,
                options: options,
                pricingRefresh: PricingRefreshOptions(
                    provider: .claude,
                    isAllowed: allowPricingRefresh,
                    retryUnknown: retryUnknownPricing,
                    inBackground: refreshPricingInBackground),
                modelsDevClient: modelsDevClient))
        }

        // Rolling window is inclusive, so a 30-day display starts 29 days before `now`.
        let since = options.calendar.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now
        await Self.refreshPricingIfAllowed(
            options: PricingRefreshOptions(
                provider: provider,
                isAllowed: allowPricingRefresh,
                retryUnknown: retryUnknownPricing,
                inBackground: refreshPricingInBackground),
            now: now,
            cacheRoot: options.cacheRoot,
            client: modelsDevClient)

        if provider == .claude {
            options.claudeLogProviderFilter = .excludeVertexAI
        }
        if forceRefresh || bypassScannerDebounce {
            options.refreshMinIntervalSeconds = 0
        }
        let scanOptions = options
        // These synchronous scans can run for minutes on large archives. The dedicated queue keeps
        // them off the cooperative pool and bridges task cancellation into scanner-level checks.
        let daily = try await CostUsageScanExecutor.run { checkCancellation in
            try CostUsageScanner.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: now,
                now: now,
                options: scanOptions,
                reportContext: reportContext,
                checkCancellation: checkCancellation)
        }

        if allowPricingRefresh,
           retryUnknownPricing,
           let request = Self.unknownPricingRefreshRequest(
               provider: provider,
               daily: daily,
               now: now,
               cacheRoot: options.cacheRoot,
               client: modelsDevClient),
           await Self.refreshUnknownPricingIfNeeded(request, inBackground: refreshPricingInBackground)
        {
            return try await self.loadTokenResult(
                provider: provider,
                environment: environment,
                now: now,
                forceRefresh: forceRefresh,
                historyDays: historyDays,
                allowPricingRefresh: allowPricingRefresh,
                refreshPricingInBackground: false,
                bypassScannerDebounce: bypassScannerDebounce,
                scannerOptions: options,
                modelsDevClient: modelsDevClient,
                retryUnknownPricing: false,
                reportContext: reportContext)
        }

        return CostUsageTokenResult(snapshot: Self.tokenSnapshot(
            from: daily,
            now: now,
            historyDays: clampedHistoryDays,
            calendar: scanOptions.calendar,
            costProvenance: .listPriceEstimate,
            detailsAreComplete: true))
    }

    static func unavailableLocalSnapshot(
        now: Date,
        historyDays: Int,
        calendar: Calendar) -> CostUsageTokenSnapshot
    {
        self.tokenSnapshot(
            from: CostUsageDailyReport(data: [], summary: nil),
            now: now,
            historyDays: historyDays,
            calendar: calendar,
            historyCoverageIsEstablished: false)
    }

    struct PricingRefreshOptions: Sendable {
        let provider: UsageProvider
        let isAllowed: Bool
        let retryUnknown: Bool
        let inBackground: Bool
    }

    static func refreshPricingIfAllowed(
        options: PricingRefreshOptions,
        now: Date,
        cacheRoot: URL?,
        client: ModelsDevClient) async
    {
        guard options.isAllowed,
              options.retryUnknown,
              options.provider == .claude
        else { return }

        if options.inBackground {
            Task.detached(priority: .utility) {
                await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: cacheRoot, client: client)
            }
        } else {
            await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: cacheRoot, client: client)
        }
    }

    private struct UnknownPricingRefreshRequest: Sendable {
        let targets: Set<ModelsDevPricingTarget>
        let now: Date
        let cacheRoot: URL?
        let client: ModelsDevClient
    }

    private static func unknownPricingRefreshRequest(
        provider: UsageProvider,
        daily: CostUsageDailyReport,
        now: Date,
        cacheRoot: URL?,
        client: ModelsDevClient) -> UnknownPricingRefreshRequest?
    {
        guard provider == .claude else { return nil }
        var targets = Set<ModelsDevPricingTarget>()
        for entry in daily.data {
            for breakdown in entry.modelBreakdowns ?? [] {
                guard breakdown.costUSD == nil else { continue }
                for target in CostUsagePricing.claudeModelsDevPricingTargets(for: breakdown.modelName) {
                    targets.insert(ModelsDevPricingTarget(providerID: target.providerID, modelID: target.modelID))
                }
            }
        }
        guard !targets.isEmpty else { return nil }

        return UnknownPricingRefreshRequest(
            targets: targets,
            now: now,
            cacheRoot: cacheRoot,
            client: client)
    }

    private static func refreshUnknownPricingIfNeeded(
        _ request: UnknownPricingRefreshRequest,
        inBackground: Bool) async -> Bool
    {
        func refreshTargets() async -> Bool {
            let targetsByProvider = Dictionary(grouping: request.targets, by: \.providerID)
            for providerID in targetsByProvider.keys.sorted() {
                let modelIDs = Set(targetsByProvider[providerID, default: []].map(\.modelID))
                let outcome = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
                    providerID: providerID,
                    modelIDs: modelIDs,
                    now: request.now,
                    cacheRoot: request.cacheRoot,
                    client: request.client)
                if outcome == .pricingAvailable {
                    return true
                }
            }
            // An earlier group may refresh the shared catalog without resolving its own alias.
            let catalog = ModelsDevCache.load(now: request.now, cacheRoot: request.cacheRoot).artifact?.catalog
            return request.targets.contains {
                catalog?.pricing(providerID: $0.providerID, modelID: $0.modelID) != nil
            }
        }

        if inBackground {
            Task.detached(priority: .utility) {
                _ = await refreshTargets()
            }
            return false
        }
        return await refreshTargets()
    }

    /// Providers whose token-cost snapshot `loadTokenSnapshot` can produce. Cursor is
    /// macOS-only because it reuses the macOS Cursor session resolution.
    static func supportsTokenSnapshot(_ provider: UsageProvider) -> Bool {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenSnapshot
    }

    static func tokenSnapshot(
        from daily: CostUsageDailyReport,
        now: Date,
        historyDays: Int = 30,
        currencyCode: String = "USD",
        useCurrentLocalDayForSession: Bool = true,
        calendar: Calendar = .current,
        historyCoverageIsEstablished: Bool = true,
        historyScanIsPartial: Bool = false,
        monetaryValuesAreAvailable: Bool = true,
        meteredCostUSD: Double? = nil,
        costProvenance: CostProvenance = .unknown,
        credentialScopeFingerprint: String? = nil,
        historyLabel: String? = nil,
        projects: [CostUsageProjectBreakdown] = [],
        sessions: [CostUsageSessionBreakdown] = [],
        detailsAreComplete: Bool = false,
        updatedAt: Date? = nil) -> CostUsageTokenSnapshot
    {
        let sessionEntry = useCurrentLocalDayForSession
            ? CostUsageTokenSnapshot.entry(in: daily.data, forLocalDayContaining: now, calendar: calendar)
            : CostUsageTokenSnapshot.latestEntry(in: daily.data)
        let requests = daily.data.compactMap(\.requestCount)
        let requestsAreComplete = !requests.isEmpty && requests.count == daily.data.count
        let establishedEmptyHistory = historyCoverageIsEstablished && !historyScanIsPartial && daily.data.isEmpty
        let emptySession: Int? = historyCoverageIsEstablished && !historyScanIsPartial ? 0 : nil
        let sessionCostUSD = monetaryValuesAreAvailable
            ? (sessionEntry.map(\.costUSD) ?? emptySession.map(Double.init)) : nil
        // Prefer summary totals when present; fall back to summing daily entries. A non-empty
        // row set where every row carries an explicit value is a known total even when it sums
        // to zero; keep nil only for genuinely missing values.
        let last30DaysCostUSD = monetaryValuesAreAvailable ? daily.summary?.totalCostUSD
            ?? (!daily.data.isEmpty && daily.data.allSatisfy { $0.costUSD != nil }
                ? daily.data.compactMap(\.costUSD).reduce(0, +)
                : establishedEmptyHistory ? 0 : nil) : nil
        let last30DaysTokens = daily.summary?.totalTokens
            ?? (!daily.data.isEmpty && daily.data.allSatisfy { $0.totalTokens != nil }
                ? CheckedSum.integers(daily.data.compactMap(\.totalTokens))
                : establishedEmptyHistory ? 0 : nil)

        return CostUsageTokenSnapshot(
            sessionTokens: sessionEntry.map(\.totalTokens) ?? emptySession,
            sessionCostUSD: sessionCostUSD,
            sessionRequests: sessionEntry.map(\.requestCount) ?? (requests.isEmpty ? nil : emptySession),
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            last30DaysRequests: requestsAreComplete ? CheckedSum.integers(requests) : nil,
            currencyCode: currencyCode,
            historyDays: historyDays,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            historyScanIsPartial: historyScanIsPartial,
            historyLabel: historyLabel,
            meteredCostUSD: monetaryValuesAreAvailable ? meteredCostUSD : nil,
            costProvenance: costProvenance,
            credentialScopeFingerprint: credentialScopeFingerprint,
            daily: daily.data,
            projects: projects,
            sessions: sessions,
            detailsAreComplete: detailsAreComplete,
            hourly: daily.hourly,
            quotaSlices: daily.quotaSlices,
            updatedAt: updatedAt ?? now)
    }
}
