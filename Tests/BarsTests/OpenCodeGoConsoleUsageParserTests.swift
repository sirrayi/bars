import Foundation
import Testing
@testable import BarsCore

struct OpenCodeGoConsoleUsageParserTests {
    private func loadExportFixture() throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: "usage-export",
            withExtension: "csv",
            subdirectory: "Fixtures/Providers/OpenCodeGo"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test
    func `converts console micro-cents to dollars`() {
        #expect(OpenCodeGoConsoleUsageParser.usd(fromMicroCents: "6000000000") == 60)
        #expect(OpenCodeGoConsoleUsageParser.usd(fromMicroCents: "110924908") == 1.10924908)
        #expect(OpenCodeGoConsoleUsageParser.usd(fromMicroCents: 100) == 0.000001)
        #expect(OpenCodeGoConsoleUsageParser.usd(fromMicroCents: nil) == nil)
        #expect(OpenCodeGoConsoleUsageParser.usd(fromMicroCents: "") == nil)
        #expect(OpenCodeGoConsoleUsageParser.usd(fromMicroCents: "1.5") == nil)
    }

    @Test
    func `reads micro-cent quota meters as exact fractions rather than truncated percents`() throws {
        let text = """
        {"access":{"startsAt":"2026-10-29T19:07:22.000Z","endsAt":"2026-11-29T19:07:22.000Z",
         "meters":{
           "fiveHour":{"startsAt":"2026-10-30T21:38:22.000Z","resetsAt":"2026-10-31T02:38:22.000Z",
             "limitMicroCents":"1200000000","usedMicroCents":"11866776"},
           "week":{"startsAt":"2026-10-26T00:00:00.000Z","resetsAt":"2026-11-02T00:00:00.000Z",
             "limitMicroCents":"3000000000","usedMicroCents":"110924908"},
           "month":{"resetsAt":"2026-11-29T19:07:22.000Z",
             "limitMicroCents":"6000000000","usedMicroCents":"110924908"}}}}
        """
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-30T22:00:00Z"))
        let snapshot = try #require(OpenCodeGoUsageFetcher.parseConsoleGoStatus(text: text, now: now))

        // Exact fractions. The public API truncates these to 0 / 3 / 1 whole percents, which is why
        // the menu reported "99% left" against a website showing 2% used.
        #expect(abs(snapshot.rollingUsagePercent - 0.988898) < 0.000001)
        #expect(abs(snapshot.weeklyUsagePercent - 3.6974969) < 0.000001)
        #expect(abs(snapshot.monthlyUsagePercent - 1.84874847) < 0.000001)
        #expect(snapshot.hasWeeklyUsage)
        #expect(snapshot.hasMonthlyUsage)
        // From 2026-10-30T22:00:00Z to 2026-11-29T19:07:22Z: 30 days minus 2h 52m 38s.
        #expect(snapshot.monthlyResetInSec == 30 * 24 * 60 * 60 - (2 * 60 * 60 + 52 * 60 + 38))
    }

    @Test
    func `rolls window totals up from the export rows`() throws {
        let rows = try OpenCodeGoConsoleUsageParser.parseExport(text: self.loadExportFixture())
        let billed = try #require(OpenCodeGoConsoleUsageParser.billedUsage(
            rows: rows,
            historyDays: 30,
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000)))

        // Totals are the sum of the billable rows; the free `opencode` row contributes nothing.
        #expect(billed.requests == 4025 + 616 + 36 + 2 + 820 + 2 + 422 + 6)
        #expect(billed.inputTokens == 3_153_822 + 1_662_974 + 69184 + 15880 + 3_008_682 + 30886 + 1_888_025 + 12920)
        #expect(billed.outputTokens == 714_224 + 289_594 + 40854 + 224 + 588_989 + 64 + 256_290 + 1827)
        #expect(billed
            .cacheReadTokens == 16_675_072 + 8_124_480 + 1_321_728 + 512 + 96_398_976 + 5888 + 33_984_384 + 4608)
        #expect(billed.cacheCreationTokens == 0)
        // Rolling the rows up locally reproduces the Console's own `usage/summary` total, which is
        // why that extra round trip is no longer made.
        #expect(abs((billed.costUSD ?? 0) - 3.22101838) < 0.0000001)
        #expect(billed.daily.count == 7)
        #expect(billed.models.map(\.model) == ["deepseek-v4.1-flash", "deepseek-v4-pro"])
        #expect(billed.models.first?.requests == 4025 + 616 + 36 + 2 + 820 + 2 + 422)
    }

    @Test
    func `groups export rows into one billed entry per day, excluding unbilled providers`() throws {
        let rows = try OpenCodeGoConsoleUsageParser.parseExport(text: self.loadExportFixture())
        #expect(rows.count == 9)

        let entries = OpenCodeGoConsoleUsageParser.dailyEntries(rows: rows)

        #expect(entries.map(\.date) == [
            "2026-10-02", "2026-10-06", "2026-10-10", "2026-10-11", "2026-10-15", "2026-10-29", "2026-10-30",
        ])
        let last = try #require(entries.last)
        #expect(abs((last.costUSD ?? 0) - 0.58877742) < 0.0000001)
        // flash 1,888,025 + 256,290 + 33,984,384, plus pro 12,920 + 1,827 + 4,608.
        #expect(last.totalTokens == 36_148_054)
        #expect(last.requestCount == 428)
        #expect(last.modelsUsed == ["deepseek-v4.1-flash", "deepseek-v4-pro"])
        // The free `opencode` provider row is metered at zero and is not this provider's spend.
        let oct29 = try #require(entries.first { $0.date == "2026-10-29" })
        #expect(oct29.modelsUsed == ["deepseek-v4.1-flash"])
        #expect(oct29.requestCount == 4025)
    }

    @Test
    func `parses the export with either CRLF or LF line endings`() throws {
        let crlf = try self.loadExportFixture()
        // The Console sends CRLF, which Swift stores as one grapheme cluster; LF must parse identically.
        let lf = crlf.replacingOccurrences(of: "\r\n", with: "\n")

        let crlfEntries = OpenCodeGoConsoleUsageParser.dailyEntries(
            rows: OpenCodeGoConsoleUsageParser.parseExport(text: crlf))
        let lfEntries = OpenCodeGoConsoleUsageParser.dailyEntries(
            rows: OpenCodeGoConsoleUsageParser.parseExport(text: lf))

        #expect(crlfEntries.count == 7)
        #expect(lfEntries.count == 7)
        #expect(crlfEntries.map(\.date) == lfEntries.map(\.date))
        #expect(crlfEntries.map(\.costUSD) == lfEntries.map(\.costUSD))
    }

    @Test
    func `activity fallback keeps per-day totals`() throws {
        let text = """
        {"startsAt":"2026-10-29T19:07:22.000Z","daily":[
         {"date":"2026-10-29","totalCostMicroCents":"95163306","totalTokens":"20543118","totalRequests":"4025"},
         {"date":"2026-10-30","totalCostMicroCents":"48736804","totalTokens":"20388324","totalRequests":"349"}],
         "models":[{"provider":"opencode-go","model":"deepseek-v4.1-flash","totalRequests":"4369"}]}
        """
        let activity = try #require(OpenCodeGoConsoleUsageParser.parseActivity(text: text))
        #expect(activity.days.count == 2)

        let billed = try #require(OpenCodeGoConsoleUsageParser.billedUsage(
            activityDays: activity.days,
            historyDays: 30,
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000)))
        #expect(billed.daily.map(\.date) == ["2026-10-29", "2026-10-30"])
        #expect(billed.daily.first?.costUSD == 0.95163306)
        #expect(billed.daily.first?.totalTokens == 20_543_118)
        #expect(abs((billed.costUSD ?? 0) - 1.4390011) < 0.0000001)
        #expect(billed.totalTokens == 20_543_118 + 20_388_324)
        // The activity feed splits no token classes; unmeasured classes stay nil rather than zero.
        #expect(billed.inputTokens == nil)
        #expect(billed.daily.first?.inputTokens == nil)
    }

    @Test
    func `an export with no billable rows falls through to no billed usage`() {
        let rows: [OpenCodeGoConsoleUsageParser.ExportRow] = []
        #expect(OpenCodeGoConsoleUsageParser.billedUsage(
            rows: rows,
            historyDays: 30,
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000)) == nil)
    }

    @Test
    func `console ranges map to the fixed window presets`() {
        #expect(OpenCodeGoConsoleFetcher.range(historyDays: 1) == "7d")
        #expect(OpenCodeGoConsoleFetcher.range(historyDays: 7) == "7d")
        #expect(OpenCodeGoConsoleFetcher.range(historyDays: 8) == "30d")
        #expect(OpenCodeGoConsoleFetcher.range(historyDays: 30) == "30d")
        #expect(OpenCodeGoConsoleFetcher.range(historyDays: 31) == "all")
    }

    @Test
    func `billed snapshots report vendor-metered provenance`() {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-10-30",
            inputTokens: 100,
            outputTokens: 20,
            totalTokens: 120,
            requestCount: 1,
            costUSD: 0.5,
            modelsUsed: ["deepseek-v4.1-flash"],
            modelBreakdowns: nil)
        let billed = OpenCodeGoBilledUsage(
            historyDays: 30,
            totalTokens: 120,
            costUSD: 0.5,
            daily: [entry],
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000))
        let snapshot = OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 1,
            weeklyUsagePercent: 4,
            monthlyUsagePercent: 2,
            rollingResetInSec: 60,
            weeklyResetInSec: 60,
            monthlyResetInSec: 60,
            daily: [entry],
            billed: billed,
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000))

        let tokenSnapshot = snapshot.toCostUsageTokenSnapshot(historyDays: 30)
        #expect(tokenSnapshot.costProvenance == .vendorMetered)
        #expect(tokenSnapshot.meteredCostUSD == 0.5)

        let localOnly = OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 1,
            weeklyUsagePercent: 4,
            monthlyUsagePercent: 2,
            rollingResetInSec: 60,
            weeklyResetInSec: 60,
            monthlyResetInSec: 60,
            daily: [entry],
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000))
        #expect(localOnly.toCostUsageTokenSnapshot(historyDays: 30).costProvenance == .listPriceEstimate)
    }

    @Test
    func `metered overlay adopts console windows and billed history together`() {
        let localEntry = CostUsageDailyReport.Entry(
            date: "2026-10-30",
            inputTokens: 1,
            outputTokens: 1,
            totalTokens: 2,
            requestCount: 1,
            costUSD: 9,
            modelsUsed: ["local"],
            modelBreakdowns: nil)
        let serverEntry = CostUsageDailyReport.Entry(
            date: "2026-10-30",
            inputTokens: 5,
            outputTokens: 5,
            totalTokens: 10,
            requestCount: 2,
            costUSD: 0.25,
            modelsUsed: ["deepseek-v4.1-flash"],
            modelBreakdowns: nil)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let local = OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 0,
            weeklyUsagePercent: 3,
            monthlyUsagePercent: 1,
            rollingResetInSec: 10,
            weeklyResetInSec: 20,
            monthlyResetInSec: 30,
            daily: [localEntry],
            updatedAt: now)
        let metered = OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 0.99,
            weeklyUsagePercent: 3.7,
            monthlyUsagePercent: 1.85,
            rollingResetInSec: 11,
            weeklyResetInSec: 21,
            monthlyResetInSec: 31,
            daily: [serverEntry],
            billed: OpenCodeGoBilledUsage(historyDays: 30, costUSD: 0.25, daily: [serverEntry], updatedAt: now),
            updatedAt: now)

        let applied = local.applyingMeteredUsage(metered)

        #expect(applied.rollingUsagePercent == 0.99)
        #expect(applied.weeklyUsagePercent == 3.7)
        #expect(applied.monthlyUsagePercent == 1.85)
        #expect(applied.daily.map(\.date) == ["2026-10-30"])
        #expect(applied.daily.first?.costUSD == 0.25)
        #expect(applied.billed?.costUSD == 0.25)
        #expect(applied.updatedAt == now)
    }

    @Test
    func `metered overlay keeps the local estimate when the console reports a balance only`() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let local = OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 5,
            weeklyUsagePercent: 6,
            monthlyUsagePercent: 7,
            rollingResetInSec: 10,
            weeklyResetInSec: 20,
            monthlyResetInSec: 30,
            updatedAt: now)

        let applied = local.applyingMeteredUsage(.zenBalanceOnly(balanceUSD: 4, updatedAt: now))

        #expect(applied.monthlyUsagePercent == 7)
        #expect(applied.zenBalanceUSD == 4)
    }
}
