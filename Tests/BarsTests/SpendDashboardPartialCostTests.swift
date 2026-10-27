import BarsCore
import Foundation
import Testing
@testable import Bars

struct SpendDashboardPartialCostTests {
    @Test
    func `established empty Codex history renders zero spend`() throws {
        let snapshot = Self.snapshot(
            entries: [],
            last30DaysTokens: 0,
            last30DaysCostUSD: 0)
        let group = try Self.group(snapshot)

        #expect(group.totalCost == 0)
        #expect(group.totalTokens == 0)
        #expect(group.coveredDayCount == 2)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `unestablished empty Codex history keeps spend unavailable`() throws {
        let snapshot = Self.snapshot(
            entries: [],
            historyCoverageIsEstablished: false,
            last30DaysTokens: 0,
            last30DaysCostUSD: 0)
        let group = try Self.group(snapshot)

        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.coveredDayCount == 0)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `incomplete Codex history with an unresolved day keeps spend unavailable`() throws {
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-15", cost: 3, tokens: 30, model: "gpt-5.4-mini"),
                Self.entry(day: "2026-07-16", cost: nil, tokens: 400_000, model: "gpt-5.6-sol"),
            ],
            historyCoverageIsEstablished: false,
            last30DaysTokens: 400_030,
            last30DaysCostUSD: 3)
        let group = try Self.group(snapshot)

        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(group.totalCost == nil)
        #expect(group.coveredDayCount == 0)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `established Codex rows without aggregate proof keep partial spend unavailable`() throws {
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-15", cost: 3, tokens: 30, model: "gpt-5.4-mini"),
                Self.entry(day: "2026-07-16", cost: nil, tokens: 400_000, model: "gpt-5.6-sol"),
            ],
            last30DaysTokens: 400_030,
            last30DaysCostUSD: nil)
        let group = try Self.group(snapshot)

        #expect(snapshot.historyCoverageIsEstablished)
        #expect(group.totalCost == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.dailyPoints.map(\.cost) == [3])
    }

    @Test
    func `established fully priced Codex history remains complete`() throws {
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-15", cost: 3, tokens: 30, model: "gpt-5.4-mini"),
                Self.entry(day: "2026-07-16", cost: 4, tokens: 40, model: "gpt-5.6-sol"),
            ],
            last30DaysTokens: 70,
            last30DaysCostUSD: 7)
        let group = try Self.group(snapshot)

        #expect(group.totalCost == 7)
        #expect(group.totalTokens == 70)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.dailyPoints.map(\.cost) == [3, 4])
    }

    @Test
    func `unpriced named models stay listed when spend is unavailable`() throws {
        let snapshot = Self.snapshot(
            entries: [Self.entry(day: "2026-07-15", cost: nil, tokens: 100, model: "deepseek-v4-flash")],
            last30DaysTokens: 100,
            last30DaysCostUSD: nil)
        let group = try Self.group(inputs: [
            .init(provider: .claude, displayName: "Claude", snapshot: snapshot),
        ])

        #expect(group.totalCost == nil)
        #expect(group.totalTokens == 100)
        #expect(group.models.map(\.modelName) == ["deepseek-v4-flash"])
        #expect(group.models.map(\.totalCost) == [nil])
        #expect(group.models.map(\.totalTokens) == [100])
        #expect(group.modelHistoryCompleteness == .incomplete)
    }

    @Test
    func `model-less unpriced history stays unavailable instead of listing a lower bound`() throws {
        let modelLess = CostUsageDailyReport.Entry(
            date: "2026-07-15",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let group = try Self.group(inputs: [
            .init(
                provider: .claude,
                displayName: "Claude",
                snapshot: Self.snapshot(
                    entries: [modelLess],
                    last30DaysTokens: 100,
                    last30DaysCostUSD: nil)),
        ])

        #expect(group.totalCost == nil)
        #expect(group.models.isEmpty)
        #expect(group.modelHistoryCompleteness == .incomplete)
    }

    @Test
    func `provider hierarchy retains incomplete source and model rows beside known subtotals`() throws {
        let provider = UsageProvider.claude
        let pending = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil,
            modelsUsed: ["fixture-pending"],
            modelBreakdowns: [.init(
                modelName: "fixture-pending", costUSD: nil, totalTokens: nil, incompleteRequestCount: 2)])
        let group = try Self.group(inputs: [
            .init(
                id: "known-source",
                provider: provider,
                displayName: "Known source",
                snapshot: Self.snapshot(
                    entries: [Self.entry(day: "2026-07-15", cost: 4, tokens: 40, model: "fixture-known")],
                    last30DaysTokens: 40,
                    last30DaysCostUSD: 4)),
            .init(
                id: "pending-source",
                provider: provider,
                displayName: "Pending source",
                snapshot: Self.snapshot(entries: [pending], last30DaysTokens: nil, last30DaysCostUSD: nil)),
        ])
        let breakdown = try #require(spendDashboardProviderBreakdowns(group).first)
        #expect(Set(breakdown.subscriptions.map(\.id)) == ["known-source", "pending-source"])
        #expect(breakdown.totalCost == 4)
        #expect(breakdown.totalTokens == 40)
        #expect(breakdown.incompleteRequestCount == 2)
        #expect(breakdown.hasPartialCost && breakdown.hasPartialTokens && breakdown.hasPartialModelHistory)
        let pendingModel = try #require(breakdown.models.first { $0.modelName == "fixture-pending" })
        #expect(pendingModel.totalCost == nil)
        #expect(pendingModel.totalTokens == nil)
        #expect(pendingModel.incompleteRequestCount == 2)
    }

    @Test
    func `provider model expansion retains incomplete rows beyond the initial display limit`() throws {
        var models = (1...8).map {
            CostUsageDailyReport.ModelBreakdown(modelName: "fixture-model-\($0)", costUSD: 1, totalTokens: 10)
        }
        models.append(.init(modelName: "fixture-incomplete", costUSD: nil, totalTokens: nil, incompleteRequestCount: 2))
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: 80,
            outputTokens: 0,
            totalTokens: 80,
            costUSD: 8,
            modelsUsed: nil,
            modelBreakdowns: models)
        let group = try Self.group(Self.snapshot(entries: [entry], last30DaysTokens: 80, last30DaysCostUSD: 8))
        let provider = try #require(spendDashboardProviderBreakdowns(group).first)
        #expect(provider.models.count == 9)
        #expect(provider.modelCount == 9)
        #expect(provider.models.last?.modelName == "fixture-incomplete")
        #expect(provider.models.last?.incompleteRequestCount == 2)
    }

    private static func group(_ snapshot: CostUsageTokenSnapshot) throws -> SpendDashboardModel.CurrencyGroup {
        try self.group(inputs: [.init(provider: .opencode, displayName: "Codex", snapshot: snapshot)])
    }

    private static func group(
        inputs: [SpendDashboardModel.ProviderInput]) throws -> SpendDashboardModel.CurrencyGroup
    {
        try #require(SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 30,
            now: self.now,
            calendar: self.calendar).groups.first)
    }

    private static func snapshot(
        entries: [CostUsageDailyReport.Entry],
        historyCoverageIsEstablished: Bool = true,
        last30DaysTokens: Int?,
        last30DaysCostUSD: Double?,
        costProvenance: CostProvenance = .unknown,
        historyScanIsPartial: Bool = false,
        historyDays: Int = 2) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            historyDays: historyDays,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            historyScanIsPartial: historyScanIsPartial,
            costProvenance: costProvenance,
            daily: entries,
            updatedAt: self.now)
    }

    private static func entry(
        day: String,
        cost: Double?,
        tokens: Int,
        model: String) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [.init(modelName: model, costUSD: cost, totalTokens: tokens)])
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
