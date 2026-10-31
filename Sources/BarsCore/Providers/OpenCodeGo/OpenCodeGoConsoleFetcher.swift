import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// API-key reads of OpenCode's Console endpoints.
///
/// The Console meters Go quota in micro-cents, so it reports percentages as exact fractions instead
/// of the whole-number percents `GET /zen/go/v1/usage` truncates to (1% reserved against 1.85% actual).
/// It also reports the workspace's metered spend and billed token counts, which no local file carries
/// for an account whose usage happened on another device or before this Mac's OpenCode history began.
enum OpenCodeGoConsoleFetcher {
    /// One authenticated Console read's shared transport context.
    struct Read {
        let apiKey: String
        let timeout: TimeInterval
        let session: URLSession
    }

    /// Go subscription meters, in micro-cents.
    static let goStatusURL = URL(string: "https://opencode.ai/console/api/go/status")!
    /// Per-day, per-model billed rows for the requested window. The rows carry every column the
    /// summary and per-model endpoints expose, so rolling them up locally costs one request instead
    /// of three — and the export is already the slowest of the three, so the others rode along inside
    /// its wait for free.
    static let usageExportURL = URL(string: "https://opencode.ai/console/api/v2/usage/export")!
    /// Per-day totals for the current Go billing period; the export's fallback.
    static let goActivityURL = URL(string: "https://opencode.ai/console/api/activity/go")!
    /// Prepaid Zen balance, readable with the same key instead of a session cookie.
    static let billingStatusURL = URL(string: "https://opencode.ai/console/api/billing/status")!

    /// Console windows are fixed presets; anything longer than 30 days uses the unbounded window.
    static func range(historyDays: Int) -> String {
        switch historyDays {
        case ..<8: "7d"
        case ...30: "30d"
        default: "all"
        }
    }

    /// Reads the exact micro-cent quota meters. Returns `nil` when the Console is reachable but does
    /// not report Go access, so callers can fall back to the public API instead of failing.
    static func fetchMeters(read: Read, now: Date = Date()) async throws -> OpenCodeGoUsageSnapshot? {
        let text = try await self.fetchText(url: self.goStatusURL, read: read)
        guard let text else { return nil }
        return OpenCodeGoUsageFetcher.parseConsoleGoStatus(text: text, now: now)
    }

    /// Reads the prepaid Zen balance with the API key, which keeps the balance row available without
    /// a browser session. Unsigned or absent balances answer `nil` rather than failing the fetch.
    static func fetchZenBalance(read: Read) async throws -> Double? {
        guard let text = try await self.fetchText(url: self.billingStatusURL, read: read) else {
            return nil
        }
        return try? OpenCodeGoZenBalanceParser.parseConsoleBillingStatus(text: text)
    }

    /// Reads metered spend and billed token counts for the configured cost window.
    static func fetchBilledUsage(
        read: Read,
        historyDays: Int,
        now: Date = Date(),
        cache: OpenCodeGoExportCache = OpenCodeGoExportCache()) async throws -> OpenCodeGoBilledUsage?
    {
        let range = self.range(historyDays: historyDays)
        let exportText = try await self.exportText(read, range: range, now: now, cache: cache)
        if let exportText {
            let rows = OpenCodeGoConsoleUsageParser.parseExport(text: exportText)
            if let billed = OpenCodeGoConsoleUsageParser.billedUsage(
                rows: rows,
                historyDays: historyDays,
                updatedAt: now)
            {
                return billed
            }
        }
        // The per-day export is gone; the billing period's own daily feed still reports metered cost
        // and total tokens, just without the token-class split.
        guard let activityText = try await self.fetchText(
            url: self.url(self.goActivityURL, range: range),
            read: read),
            let activity = OpenCodeGoConsoleUsageParser.parseActivity(text: activityText)
        else {
            return nil
        }
        return OpenCodeGoConsoleUsageParser.billedUsage(
            activityDays: activity.days,
            historyDays: historyDays,
            updatedAt: now)
    }

    /// Reuses a recently fetched export when one exists, otherwise fetches and caches it.
    private static func exportText(
        _ read: Read,
        range: String,
        now: Date,
        cache: OpenCodeGoExportCache) async throws -> String?
    {
        if let cached = cache.load(range: range, now: now) { return cached }
        guard let text = try await self.fetchText(
            url: self.url(self.usageExportURL, range: range),
            read: read)
        else {
            return nil
        }
        cache.store(text, range: range)
        return text
    }

    private static func url(_ base: URL, range: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "range", value: range)]
        return components?.url ?? base
    }

    /// Answers `nil` for a reachable Console that has no payload for this key (an expected no-access
    /// case), and throws only for expired credentials or transport failures.
    private static func fetchText(url: URL, read: Read) async throws -> String? {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = read.timeout
        request.setValue("Bearer \(read.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("bars", forHTTPHeaderField: "User-Agent")

        let response = try await read.session.response(for: request)
        try Task.checkCancellation()
        switch response.statusCode {
        case 200:
            guard let text = String(data: response.data, encoding: .utf8) else {
                throw OpenCodeGoUsageError.parseFailed("Console response was not UTF-8.")
            }
            return text
        case 401, 403:
            throw OpenCodeGoUsageError.invalidCredentials
        case 404:
            return nil
        default:
            return nil
        }
    }
}
