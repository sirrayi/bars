import Foundation

extension CostUsageFetcher {
    // Devin CLI keeps a local SQLite ledger of model requests. SWE-2 requests are free during the
    // promo while Claude-routed requests price through the shared models.dev catalog, so Devin
    // refreshes the Claude pricing lane rather than a Devin-specific one.
    // swiftlint:disable:next function_parameter_count
    static func loadDevinLocalSnapshot(
        environment: [String: String],
        now: Date,
        historyDays: Int,
        options: CostUsageScanner.Options,
        pricingRefresh: PricingRefreshOptions,
        modelsDevClient: ModelsDevClient) async throws -> CostUsageTokenSnapshot
    {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let calendar = options.calendar
        let cacheRoot = options.cacheRoot
        let since = calendar.date(
            byAdding: .day, value: -(max(1, historyDays) - 1), to: calendar.startOfDay(for: now)) ?? now
        await Self.refreshPricingIfAllowed(
            options: pricingRefresh,
            now: now,
            cacheRoot: cacheRoot,
            client: modelsDevClient)
        let report = try await CostUsageScanExecutor.run { _ in
            try DevinLocalCostReader(homeDirectory: home).makeDailyReport(
                since: since,
                until: now,
                calendar: calendar,
                catalog: CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: cacheRoot),
                modelsDevCacheRoot: cacheRoot,
                customPricing: CostUsagePricing.customPricingOverlay())
        }
        guard let report else {
            return Self.unavailableLocalSnapshot(
                now: now,
                historyDays: historyDays,
                calendar: calendar)
        }
        return Self.tokenSnapshot(
            from: report,
            now: now,
            historyDays: historyDays,
            calendar: calendar,
            historyCoverageIsEstablished: true,
            costProvenance: .listPriceEstimate)
    }
}
