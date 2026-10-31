import Foundation

extension CostUsageFetcher {
    /// Console usage reads are one round of short GETs; keep them well inside a card refresh budget
    /// so a stalled network never delays the local fallback by the full provider timeout.
    static let openCodeGoConsoleTimeout: TimeInterval = 12

    /// Reads OpenCode Go spend and billed token counts from the workspace Console.
    ///
    /// These are the amounts OpenCode metered and charged, and they cover every device and every
    /// session since the billing period began. The device-local SQLite ledger only knows what this
    /// Mac recorded, and its recorded costs are model-implied rather than billed.
    ///
    /// Returns `nil` whenever the Console cannot answer — no API key, an expired key, an unreachable
    /// endpoint, or an empty window — so the caller falls back to the local ledger instead of
    /// replacing usable history with a failure.
    static func meteredOpenCodeGoUsage(
        environment: [String: String],
        now: Date,
        historyDays: Int,
        calendar: Calendar) async -> CostUsageTokenResult?
    {
        guard let apiKey = OpenCodeGoSettingsReader.apiKey(environment: environment) else { return nil }
        do {
            guard let billed = try await OpenCodeGoConsoleFetcher.fetchBilledUsage(
                read: OpenCodeGoConsoleFetcher.Read(
                    apiKey: apiKey,
                    timeout: Self.openCodeGoConsoleTimeout,
                    session: .shared),
                historyDays: historyDays,
                now: now),
                !billed.daily.isEmpty
            else {
                return nil
            }
            return CostUsageTokenResult(snapshot: Self.tokenSnapshot(
                from: CostUsageDailyReport(data: billed.daily, summary: nil),
                now: now,
                historyDays: historyDays,
                calendar: calendar,
                meteredCostUSD: billed.costUSD,
                costProvenance: .vendorMetered))
        } catch {
            return nil
        }
    }
}
