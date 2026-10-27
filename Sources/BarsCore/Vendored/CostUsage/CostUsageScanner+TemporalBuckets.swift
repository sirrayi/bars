import Foundation

extension CostUsageScanner {
    typealias HourlyBucket = CostUsageTemporalTotals

    struct TemporalBuckets {
        var hourly: [Date: HourlyBucket] = [:]
        var quotaSlices: [Date: HourlyBucket] = [:]
    }

    static func hourStart(for timestamp: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .hour, for: timestamp)?.start ?? timestamp
    }

    static func date(fromUnixMs millis: Int64?) -> Date? {
        millis.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    static func sortedHourlyEntries(_ buckets: [Date: HourlyBucket]) -> [CostUsageHourlyEntry] {
        buckets.keys.sorted().map { hour in
            (buckets[hour] ?? HourlyBucket()).hourlyEntry(hour: hour)
        }
    }

    static func sortedQuotaSlices(_ buckets: [Date: HourlyBucket]) -> [CostUsageTimedEntry] {
        buckets.keys.sorted().map { timestamp in
            (buckets[timestamp] ?? HourlyBucket()).timedEntry(timestamp: timestamp)
        }
    }

    static func addClaudeTemporal(
        row: ClaudeUsageRow,
        costUSD: Double?,
        range: CostUsageDayRange,
        into buckets: inout TemporalBuckets)
    {
        guard CostUsageDayRange.isInRange(dayKey: row.dayKey, since: range.sinceKey, until: range.untilKey),
              let timestamp = self.date(fromUnixMs: row.timestampUnixMs)
        else { return }
        let hour = self.hourStart(for: timestamp, calendar: range.calendar)
        var hourly = buckets.hourly[hour] ?? HourlyBucket()
        var timed = buckets.quotaSlices[timestamp] ?? HourlyBucket()
        for tokens in [row.input, row.cacheRead, row.cacheCreate, row.output] {
            hourly.addTokens(tokens)
            timed.addTokens(tokens)
        }
        hourly.addCost(costUSD)
        timed.addCost(costUSD)
        buckets.hourly[hour] = hourly
        buckets.quotaSlices[timestamp] = timed
    }
}
