import Foundation
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

extension CostUsageScanner {
    static func pruneDays(cache: inout CostUsageCache, sinceKey: String, untilKey: String) {
        for key in cache.days.keys where !CostUsageDayRange.isInRange(dayKey: key, since: sinceKey, until: untilKey) {
            cache.days.removeValue(forKey: key)
        }
    }

    static func requestedWindowExpandsCache(range: CostUsageDayRange, cache: CostUsageCache) -> Bool {
        guard let cachedSince = cache.scanSinceKey,
              let cachedUntil = cache.scanUntilKey
        else {
            return cache.lastScanUnixMs != 0 || !cache.files.isEmpty || !cache.days.isEmpty
        }
        return range.scanSinceKey < cachedSince || range.scanUntilKey > cachedUntil
    }

    static func sortedModelBreakdowns(_ breakdowns: [CostUsageDailyReport.ModelBreakdown])
        -> [CostUsageDailyReport.ModelBreakdown]
    {
        breakdowns.sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? -1
            let rhsCost = rhs.costUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }

            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }

            return lhs.modelName > rhs.modelName
        }
    }

    static func parseDayKey(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return nil }
        guard
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else { return nil }

        let calendar = CostUsageDayRange.localGregorianCalendar(matching: calendar)
        var comps = DateComponents()
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return comps.date
    }
}

extension Data {
    func containsAscii(_ needle: String) -> Bool {
        guard let n = needle.data(using: .utf8) else { return false }
        guard !n.isEmpty else { return self.range(of: n) != nil }
        guard n.count <= self.count else { return false }
        return self.withUnsafeBytes { haystack in
            n.withUnsafeBytes { pattern in
                guard let base = haystack.baseAddress, let needleBase = pattern.baseAddress else { return false }
                let first = Int32(pattern[0])
                let limit = haystack.count - pattern.count + 1
                var offset = 0
                while offset < limit {
                    guard let candidate = memchr(base.advanced(by: offset), first, limit - offset) else { return false }
                    if memcmp(candidate, needleBase, pattern.count) == 0 { return true }
                    offset = base.distance(to: UnsafeRawPointer(candidate)) + 1
                }
                return false
            }
        }
    }
}

extension [Int] {
    subscript(safe index: Int) -> Int? {
        self.indices.contains(index) ? self[index] : nil
    }
}

extension [UInt8] {
    subscript(safe index: Int) -> UInt8? {
        self.indices.contains(index) ? self[index] : nil
    }
}
