#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CoreFoundation
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum CostUsageScanner {
    typealias CancellationCheck = () throws -> Void

    static let log = BarsLog.logger(LogCategories.tokenCost)
    static let costScale = 1_000_000_000.0

    enum ClaudeLogProviderFilter {
        case all
        case vertexAIOnly
        case excludeVertexAI
    }

    struct Options {
        var claudeProjectsRoots: [URL]?
        var cacheRoot: URL?
        var calendar: Calendar
        var refreshMinIntervalSeconds: TimeInterval = 60
        var claudeLogProviderFilter: ClaudeLogProviderFilter = .all
        /// Force a full rescan, ignoring per-file cache and incremental offsets.
        var forceRescan: Bool = false

        init(
            claudeProjectsRoots: [URL]? = nil,
            cacheRoot: URL? = nil,
            calendar: Calendar = .current,
            claudeLogProviderFilter: ClaudeLogProviderFilter = .all,
            forceRescan: Bool = false)
        {
            self.claudeProjectsRoots = claudeProjectsRoots
            self.cacheRoot = cacheRoot
            self.calendar = calendar
            self.claudeLogProviderFilter = claudeLogProviderFilter
            self.forceRescan = forceRescan
        }
    }

    struct ClaudeParseResult {
        let rows: [ClaudeUsageRow]
        let parsedBytes: Int64
    }

    enum ClaudePathRole: String, Codable, Equatable {
        case parent
        case subagent
    }

    struct ClaudeUsageRow: Codable, Equatable {
        let dayKey: String
        let model: String
        let sessionId: String?
        let messageId: String?
        let requestId: String?
        let timestampUnixMs: Int64?
        let isSidechain: Bool
        let pathRole: ClaudePathRole
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let cacheCreate1h: Int?
        let output: Int
        let costNanos: Int
        let costPriced: Bool?
        var isIncomplete: Bool?
    }

    static func loadDailyReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options()) -> CostUsageDailyReport
    {
        (
            try? self.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: options,
                checkCancellation: nil)) ?? CostUsageDailyReport(data: [], summary: nil)
    }

    static func loadDailyReportCancellable(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        try checkCancellation?()
        // Provider-specific by design: only Claude transcripts have a local JSONL cost scanner.
        guard provider == .claude else { return CostUsageDailyReport(data: [], summary: nil) }
        return try self.loadClaudeDaily(
            provider: .claude,
            range: CostUsageDayRange(since: since, until: until, calendar: options.calendar),
            now: now,
            options: options,
            checkCancellation: checkCancellation)
    }

    // MARK: - Day keys

    struct CostUsageDayRange {
        let sinceKey: String
        let untilKey: String
        private(set) var scanSinceKey: String
        private(set) var scanUntilKey: String
        let calendar: Calendar

        init(since: Date, until: Date, calendar: Calendar = .current) {
            let calendar = Self.localGregorianCalendar(matching: calendar)
            self.calendar = calendar
            self.sinceKey = Self.dayKey(from: since, calendar: calendar)
            self.untilKey = Self.dayKey(from: until, calendar: calendar)
            let scanSince = calendar.date(byAdding: .day, value: -1, to: since) ?? since
            let scanUntil = calendar.date(byAdding: .day, value: 1, to: until) ?? until
            self.scanSinceKey = Self.dayKey(from: scanSince, calendar: calendar)
            self.scanUntilKey = Self.dayKey(from: scanUntil, calendar: calendar)
        }

        static func localGregorianCalendar(matching calendar: Calendar = .current) -> Calendar {
            CostUsageLocalDay.gregorianCalendar(matching: calendar)
        }

        func retainingScanWindow(since scanSinceKey: String, until scanUntilKey: String) -> Self {
            var retained = self
            retained.scanSinceKey = min(self.scanSinceKey, scanSinceKey)
            retained.scanUntilKey = max(self.scanUntilKey, scanUntilKey)
            return retained
        }

        static func dayKey(from date: Date, calendar: Calendar = .current) -> String {
            CostUsageLocalDay.key(from: date, calendar: calendar)
        }

        static func isInRange(dayKey: String, since: String, until: String) -> Bool {
            dayKey >= since && dayKey <= until
        }
    }

    static func localStartOfDay(_ dayKey: String, calendar: Calendar) -> Date? {
        let calendar = CostUsageDayRange.localGregorianCalendar(matching: calendar)
        return self.parseDayKey(dayKey, calendar: calendar).map { calendar.startOfDay(for: $0) }
    }
}
