import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ShareStatsCompletenessTests {
    @Test
    func `one incomplete account excludes only its provider`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let model = SpendDashboardModel.build(
            inputs: [
                Self.input(provider: .codex, name: "Codex A", model: "gpt-4o", tokens: 300, cost: 3),
                Self.input(provider: .codex, name: "Codex B", model: "gpt-4o", tokens: 100, cost: 1, incomplete: 1),
                Self.input(provider: .claude, name: "Claude", model: "claude-sonnet-4", tokens: 200, cost: 2),
            ],
            requestedDays: 7,
            now: Self.now,
            calendar: calendar)
        let payload = try #require(ShareStatsBuilder.make(model: model))

        #expect(payload.providers.count == 3)
        #expect(payload.hasPartialModels)
        #expect(payload.topModels.map(\.provider) == [.claude])
        #expect(payload.topModels.first?.totalTokens == 200)
    }

    @Test(arguments: [0, -1])
    func `selected day models are not advertised as the full reporting window`(dayOffset: Int) throws {
        let payload = try #require(ShareStatsBuilder.make(model: Self.dashboard(
            scenario: "complete",
            selectedDay: Self.now.addingTimeInterval(Double(dayOffset) * 86400))))

        #expect(payload.days == 7)
        #expect(payload.hasPartialModels)
        #expect(payload.modelRankingDetail == "PARTIAL")
        #expect(payload.topModels.isEmpty)
        #expect(!ShareStatsFormatting.text(payload).contains("Top models"))
    }

    @Test
    func `an idle full window does not claim a partial ranking`() throws {
        let payload = try #require(ShareStatsBuilder.make(model: Self.dashboard(
            scenario: "idle",
            selectedDay: Self.now.addingTimeInterval(-86400))))

        #expect(payload.totalTokens == 0)
        #expect(payload.currencies.first?.estimatedCost == 0)
        #expect(payload.topModels.isEmpty)
        #expect(!payload.hasPartialModels)
        #expect(payload.modelRankingDetail == "BY USAGE")
    }

    @Test(arguments: ["missing-cost", "token-overflow", "cost-overflow", "both-overflow"])
    func `family aggregation preserves unavailable amounts`(_ scenario: String) throws {
        let tokenOverflow = scenario == "token-overflow" || scenario == "both-overflow"
        let costOverflow = scenario == "cost-overflow" || scenario == "both-overflow"
        let group = try #require(Self.dashboard(scenario: "complete").groups.first)
        let models: [SpendDashboardModel.ModelRow] = [
            .init(
                rank: 1,
                provider: .codex,
                providerName: "Codex",
                modelName: "gpt-4o",
                totalTokens: tokenOverflow ? Int.max : 10,
                totalCost: costOverflow ? Double.greatestFiniteMagnitude : 1),
            .init(
                rank: 2,
                provider: .codex,
                providerName: "Codex",
                modelName: "gpt-4o-mini",
                totalTokens: 20,
                totalCost: scenario == "missing-cost" ? nil : costOverflow ? Double.greatestFiniteMagnitude : 2),
            .init(
                rank: 3,
                provider: .codex,
                providerName: "Codex",
                modelName: "gpt-fixture",
                totalTokens: 1,
                totalCost: 1),
        ]
        let payload = try #require(ShareStatsBuilder.make(model: SpendDashboardModel(requestedDays: 7, groups: [
            .init(
                currencyCode: "USD",
                providers: group.providers,
                models: models,
                dailyPoints: [],
                totalTokens: group.totalTokens,
                totalCost: group.totalCost,
                coveredDayCount: 7,
                chartDomain: group.chartDomain,
                modelHistoryCompleteness: .complete),
        ])))

        if scenario == "both-overflow" {
            #expect(payload.topModels.isEmpty)
        } else {
            let family = try #require(payload.topModels.first)
            #expect(payload.topModels.count == 1)
            #expect(family.totalTokens == (tokenOverflow ? nil : 31))
            #expect(family.estimatedCost == (costOverflow || scenario == "missing-cost" ? nil : 4))
        }
    }

    private static func input(
        provider: UsageProvider,
        name: String,
        model: String,
        tokens: Int?,
        cost: Double?,
        incomplete: Int = 0,
        hasModels: Bool = true) -> SpendDashboardModel.ProviderInput
    {
        .init(id: name, provider: provider, displayName: name, snapshot: CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [.init(
                date: "2026-07-16",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: hasModels ? [.init(
                    modelName: model,
                    costUSD: cost,
                    totalTokens: tokens,
                    incompleteRequestCount: incomplete)] : nil)],
            updatedAt: self.now))
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200)

    private static func dashboard(scenario: String, selectedDay: Date? = nil) -> SpendDashboardModel {
        let zeroBaseline = scenario == "idle" || scenario.hasPrefix("unknown")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return SpendDashboardModel.build(
            inputs: [
                Self.input(
                    provider: .codex,
                    name: "Codex",
                    model: "gpt-4o",
                    tokens: zeroBaseline ? 0 : 300,
                    cost: zeroBaseline ? 0 : 3,
                    hasModels: !zeroBaseline),
                Self.input(
                    provider: .claude,
                    name: "Claude",
                    model: "claude-sonnet-4",
                    tokens: zeroBaseline ? 0 : 200,
                    cost: zeroBaseline ? 0 : 2,
                    hasModels: !zeroBaseline),
                Self.input(
                    provider: .opencode,
                    name: "OpenCode",
                    model: "gemini-2.5-flash",
                    tokens: ["unknown", "unknown-tokens"].contains(scenario) ? nil : zeroBaseline ? 0 : 100,
                    cost: ["unknown", "unknown-cost", "unpriced"].contains(scenario) ? nil : zeroBaseline ? 0 : 1,
                    incomplete: scenario == "incomplete" ? 1 : 0,
                    hasModels: !zeroBaseline && scenario != "missing-models"),
            ],
            requestedDays: 7,
            now: Self.now,
            calendar: calendar,
            selectedDay: selectedDay)
    }
}
