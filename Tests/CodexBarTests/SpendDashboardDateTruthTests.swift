import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardDateTruthTests {
    private struct MalformedMetricCase {
        let name: String
        let breakdown: CostUsageDailyReport.ModelBreakdown
        let totalCost: Double?
        let totalTokens: Int?
        let modelHistory: SpendDashboardModel.ModelHistoryCompleteness
        let chartCost: Double?
    }

    @Test
    func `date with a valid prefix and trailing junk fails closed`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "2026-07-16junk", cost: 2, tokens: 20),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.first?.totalCost == nil)
        #expect(group.providers.first?.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `malformed rows validate cost and tokens independently`() throws {
        let cases: [MalformedMetricCase] = [
            .init(
                name: "cost",
                breakdown: .init(modelName: "spend", costUSD: 1, totalTokens: 0),
                totalCost: nil,
                totalTokens: 30,
                modelHistory: .incomplete,
                chartCost: nil),
            .init(
                name: "tokens",
                breakdown: .init(modelName: "tokens", costUSD: 0, totalTokens: 1),
                totalCost: 3,
                totalTokens: nil,
                modelHistory: .complete,
                chartCost: 3),
            .init(
                name: "requests",
                breakdown: .init(modelName: "requests", costUSD: 0, totalTokens: 0, requestCount: 1),
                totalCost: 3,
                totalTokens: 30,
                modelHistory: .complete,
                chartCost: 3),
        ]

        for testCase in cases {
            let snapshot = Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
                Self.entryWithBreakdowns(
                    day: "malformed",
                    breakdowns: [testCase.breakdown]),
            ])
            let group = try #require(SpendDashboardModel.build(
                inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
                requestedDays: 7,
                now: Self.now,
                calendar: Self.calendar).groups.first)

            #expect(group.providers.first?.totalCost == testCase.totalCost, Comment(rawValue: testCase.name))
            #expect(group.providers.first?.totalTokens == testCase.totalTokens, Comment(rawValue: testCase.name))
            #expect(group.modelHistoryCompleteness == testCase.modelHistory, Comment(rawValue: testCase.name))
            #expect(group.models.map(\.totalCost) == (testCase.totalCost == nil ? [] : [3]))
            #expect(group.dailyPoints.first?.cost == testCase.chartCost, Comment(rawValue: testCase.name))
        }
    }

    @Test
    func `coverage contradiction fails source closed across every aggregate`() throws {
        let contradictions = [
            Self.entry(day: "2026-07-15", cost: 7, tokens: 70),
            Self.entry(day: "2026-07-15", cost: nil, tokens: nil, model: nil),
        ]

        for contradiction in contradictions {
            let snapshot = Self.snapshot(
                currency: "USD",
                entries: [
                    Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
                    contradiction,
                ],
                historyDays: 1)
            let group = try #require(SpendDashboardModel.build(
                inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
                requestedDays: 7,
                now: Self.now,
                calendar: Self.calendar).groups.first)

            #expect(group.providers.first?.coveredDayCount == 1)
            #expect(group.providers.first?.totalCost == nil)
            #expect(group.providers.first?.totalTokens == nil)
            #expect(group.totalCost == nil)
            #expect(group.totalTokens == nil)
            #expect(group.modelHistoryCompleteness == .incomplete)
            #expect(group.models.isEmpty)
            #expect(group.dailyPoints.isEmpty)
        }
    }

    @Test
    func `entries inside declared coverage aggregate normally`() throws {
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [
                Self.entry(day: "2026-07-15", cost: 7, tokens: 70),
                Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
            ],
            historyDays: 2)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 10)
        #expect(group.totalTokens == 100)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.map(\.totalCost) == [10])
        #expect(group.dailyPoints.map(\.cost) == [7, 3])
    }

    @Test
    func `aggregate contradictions fail only the affected metric`() throws {
        let entry = Self.entry(day: "2026-07-16", cost: 3, tokens: 30)
        let costContradiction = Self.snapshot(
            currency: "USD",
            entries: [entry],
            last30DaysTokens: 30,
            last30DaysCostUSD: 10)
        let tokenContradiction = Self.snapshot(
            currency: "USD",
            entries: [entry],
            last30DaysTokens: 100,
            last30DaysCostUSD: 3)

        let costGroup = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: costContradiction)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)
        let tokenGroup = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: tokenContradiction)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(costGroup.totalCost == nil)
        #expect(costGroup.totalTokens == 30)
        #expect(costGroup.dailyPoints.isEmpty)
        #expect(costGroup.modelHistoryCompleteness == .incomplete)
        #expect(costGroup.models.isEmpty)

        #expect(tokenGroup.totalCost == 3)
        #expect(tokenGroup.totalTokens == nil)
        #expect(tokenGroup.dailyPoints.map(\.cost) == [3])
        #expect(tokenGroup.modelHistoryCompleteness == .complete)
        #expect(tokenGroup.models.map(\.totalCost) == [3])
        #expect(tokenGroup.models.map(\.totalTokens) == [nil])
    }

    @Test
    func `matching full history aggregates allow shorter selected window`() throws {
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [
                Self.entry(day: "2026-07-06", cost: 7, tokens: 70),
                Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
            ],
            historyDays: 30,
            last30DaysTokens: 100,
            last30DaysCostUSD: 10)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 3)
        #expect(group.totalTokens == 30)
        #expect(group.models.map(\.totalCost) == [3])
        #expect(group.models.map(\.totalTokens) == [30])
        #expect(group.dailyPoints.map(\.cost) == [3])
    }

    @Test
    func `out of request usage and proven zero outside coverage are harmless`() throws {
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [
                Self.entry(day: "2026-07-01", cost: 100, tokens: 1000),
                Self.entry(day: "2026-07-15", cost: 0, tokens: 0, model: nil),
                Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
            ],
            historyDays: 1)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 3)
        #expect(group.totalTokens == 30)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.map(\.totalCost) == [3])
        #expect(group.dailyPoints.map(\.cost) == [3])
    }

    @Test
    func `malformed zero row cannot prove contradictory nonzero aggregates`() throws {
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [Self.entry(day: "malformed", cost: 0, tokens: 0, model: nil)],
            historyDays: 1,
            last30DaysTokens: 1,
            last30DaysCostUSD: 1)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.dailyPoints.isEmpty)
    }

    private static func input(
        id: String,
        provider: UsageProvider,
        currency: String,
        cost: Double) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: provider.rawValue,
            snapshot: self.snapshot(
                currency: currency,
                entries: [self.entry(day: "2026-07-16", cost: cost)]))
    }

    private static func snapshot(
        currency: String,
        entries: [CostUsageDailyReport.Entry],
        historyDays: Int = 30,
        last30DaysTokens: Int? = nil,
        last30DaysCostUSD: Double? = nil,
        updatedAt: Date = now) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            currencyCode: currency,
            historyDays: historyDays,
            daily: entries,
            updatedAt: updatedAt)
    }

    private static func entry(
        day: String,
        cost: Double?,
        tokens: Int? = 10,
        model: String? = "test-model") -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: model.map {
                [.init(modelName: $0, costUSD: cost, totalTokens: tokens)]
            })
    }

    private static func entryWithBreakdowns(
        day: String,
        totalCost: Double = 0,
        totalTokens: Int = 0,
        breakdowns: [CostUsageDailyReport.ModelBreakdown]) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: totalTokens,
            costUSD: totalCost,
            modelsUsed: nil,
            modelBreakdowns: breakdowns)
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
