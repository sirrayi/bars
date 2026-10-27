import Foundation

/// In-memory working set for one bounded Claude scan, persisted through the compact JSON cache.
struct CostUsageCache: Codable, Equatable, @unchecked Sendable {
    var version: Int = 1
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?
    var timeZoneIdentifier: String?
    var files: [String: CostUsageFileUsage] = [:]
    var days: [String: [String: [Int]]] = [:]
    var roots: [String: Int64]?
}

/// Wire shapes for the temporal buckets persisted beside cached daily reports.
enum CostUsageCachedReport {
    struct HourlyEntry: Codable, Equatable {
        var hourUnixMs: Int64
        var totalTokens: Int?
        var costUSD: Double?
        var tokensAreComplete: Bool?
        var costIsComplete: Bool?

        init(_ entry: CostUsageHourlyEntry) {
            self.hourUnixMs = Int64((entry.hour.timeIntervalSince1970 * 1000).rounded())
            self.totalTokens = entry.totalTokens
            self.costUSD = entry.costUSD
            self.tokensAreComplete = entry.tokensAreComplete
            self.costIsComplete = entry.costIsComplete
        }

        var hourlyValue: CostUsageHourlyEntry {
            CostUsageHourlyEntry(
                hour: Date(timeIntervalSince1970: Double(self.hourUnixMs) / 1000),
                totalTokens: self.totalTokens,
                costUSD: self.costUSD,
                tokensAreComplete: self.tokensAreComplete ?? (self.totalTokens != nil),
                costIsComplete: self.costIsComplete ?? (self.costUSD != nil))
        }
    }

    struct QuotaSlice: Codable, Equatable {
        var timestampUnixMs: Int64
        var totalTokens: Int?
        var costUSD: Double?
        var tokensAreComplete: Bool?
        var costIsComplete: Bool?

        init(_ entry: CostUsageTimedEntry) {
            self.timestampUnixMs = Int64((entry.timestamp.timeIntervalSince1970 * 1000).rounded())
            self.totalTokens = entry.totalTokens
            self.costUSD = entry.costUSD
            self.tokensAreComplete = entry.tokensAreComplete
            self.costIsComplete = entry.costIsComplete
        }

        var timedValue: CostUsageTimedEntry {
            CostUsageTimedEntry(
                timestamp: Date(timeIntervalSince1970: Double(self.timestampUnixMs) / 1000),
                totalTokens: self.totalTokens,
                costUSD: self.costUSD,
                tokensAreComplete: self.tokensAreComplete ?? (self.totalTokens != nil),
                costIsComplete: self.costIsComplete ?? (self.costUSD != nil))
        }
    }
}

struct CostUsageFileUsage: Codable, Equatable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var claudeRows: [CostUsageScanner.ClaudeUsageRow]?
}
