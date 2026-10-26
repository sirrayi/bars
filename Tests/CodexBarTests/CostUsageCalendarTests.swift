import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCalendarTests {
    @Test
    func `day keys remain Gregorian under a Buddhist calendar`() throws {
        let bangkok = try #require(TimeZone(identifier: "Asia/Bangkok"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = bangkok
        let date = try #require(gregorian.date(from: DateComponents(
            timeZone: bangkok,
            year: 2026,
            month: 7,
            day: 23,
            hour: 12)))

        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = bangkok
        #expect(buddhist.component(.year, from: date) == 2569)

        let range = CostUsageScanner.CostUsageDayRange(since: date, until: date, calendar: buddhist)
        #expect(range.sinceKey == "2026-07-23")
        #expect(range.untilKey == "2026-07-23")
        #expect(range.scanSinceKey == "2026-07-22")
        #expect(range.scanUntilKey == "2026-07-24")
        #expect(CostUsageScanner.dayKeyFromTimestamp(
            "2026-07-23T05:00:00Z",
            calendar: buddhist) == "2026-07-23")
        #expect(CostUsageScanner.dayKeyFromParsedISO(
            "2026-07-23T05:00:00Z",
            calendar: buddhist) == "2026-07-23")

        let parsed = try #require(CostUsageScanner.parseDayKey("2026-07-23", calendar: buddhist))
        #expect(CostUsageScanner.CostUsageDayRange.dayKey(
            from: parsed,
            calendar: buddhist) == "2026-07-23")
    }

    @Test
    func `claude cache re-buckets unchanged files when the time zone changes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let utc = try Self.calendar(timeZoneIdentifier: "UTC")
        let bangkok = try Self.calendar(timeZoneIdentifier: "Asia/Bangkok")
        let boundary = try Self.date("2026-07-22T18:00:00Z")
        let windowStart = try Self.date("2026-07-20T12:00:00Z")
        let windowEnd = try Self.date("2026-07-24T12:00:00Z")
        _ = try env.writeClaudeProjectFile(
            relativePath: "calendar/session.jsonl",
            contents: env.jsonl([
                [
                    "type": "assistant",
                    "timestamp": env.isoString(for: boundary),
                    "sessionId": "claude-calendar-session",
                    "requestId": "claude-calendar-request",
                    "message": [
                        "id": "claude-calendar-message",
                        "model": "claude-sonnet-4-20250514",
                        "usage": [
                            "input_tokens": 10,
                            "cache_creation_input_tokens": 0,
                            "cache_read_input_tokens": 0,
                            "output_tokens": 2,
                        ],
                    ],
                ],
            ]))

        let utcClaude = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: windowStart,
            until: windowEnd,
            now: windowEnd,
            options: Self.claudeOptions(env: env, calendar: utc))
        let bangkokClaude = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: windowStart,
            until: windowEnd,
            now: windowEnd,
            options: Self.claudeOptions(env: env, calendar: bangkok))
        #expect(utcClaude.data.map(\.date) == ["2026-07-22"])
        #expect(bangkokClaude.data.map(\.date) == ["2026-07-23"])
        #expect(CostUsageClaudeCacheIO.load(
            provider: .claude,
            cacheRoot: env.cacheRoot).usage.timeZoneIdentifier == "Asia/Bangkok")
    }

    private static func claudeOptions(
        env: CostUsageTestEnvironment,
        calendar: Calendar) -> CostUsageScanner.Options
    {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func calendar(timeZoneIdentifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timeZoneIdentifier))
        return calendar
    }

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }
}
