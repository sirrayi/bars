import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct WidgetSnapshotTests {
    @Test
    func `widget cost summaries omit project names and paths`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 1,
            last30DaysTokens: 100,
            last30DaysCostUSD: 1,
            daily: [],
            projects: [.init(
                name: "Private project",
                path: "/private/work/project",
                totalTokens: 100,
                totalCostUSD: 1,
                daily: [],
                modelBreakdowns: nil)],
            updatedAt: Date(timeIntervalSince1970: 0))
        let summary = try #require(UsageStore.widgetTokenUsageSummary(from: snapshot, provider: .codex))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try #require(String(data: encoder.encode(summary), encoding: .utf8))
        #expect(summary.sessionTokens == 100)
        #expect(!encoded.contains("Private project"))
        #expect(!encoded.contains("/private/work/project"))
    }

    @Test
    func `widget token fallback keeps positive totals and rejects overflow`() {
        for (tokens, expected) in [
            ([Int?](), Int?.none),
            ([nil, 0], nil),
            ([12, nil, 30], 42),
            ([Int.max, 1, -1], nil),
            ([-1], nil),
        ] {
            let snapshot = CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                daily: tokens.enumerated().map { index, total in
                    .init(
                        date: "2026-09-\(index + 1)",
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: total,
                        costUSD: nil,
                        modelsUsed: nil,
                        modelBreakdowns: nil)
                },
                updatedAt: Date(timeIntervalSince1970: 0))
            #expect(UsageStore.widgetTokenUsageSummary(from: snapshot, provider: .claude)?.last30DaysTokens == expected)
        }
    }

    @Test
    func `widget snapshot round trip`() throws {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: Date(),
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "session", title: "Session", percentLeft: 90),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "weekly", title: "Weekly", percentLeft: 80),
            ],
            creditsRemaining: 123.4,
            codeReviewRemainingPercent: 80,
            tokenUsage: WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: 12.3,
                sessionTokens: 1200,
                last30DaysCostUSD: 456.7,
                last30DaysTokens: 9800,
                currencyCode: "eur",
                sessionLabel: "Latest billing day",
                last30DaysLabel: "This month"),
            dailyUsage: [
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-20", totalTokens: 1200, costUSD: 12.3),
            ],
            quotaOwnerKey: "claude-account-cache-key")

        let snapshot = WidgetSnapshot(
            entries: [entry],
            enabledProviders: [.codex, .claude],
            usageBarsShowUsed: true,
            generatedAt: Date())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: data)

        #expect(decoded.entries.count == 1)
        #expect(decoded.entries.first?.provider == .codex)
        #expect(decoded.entries.first?.tokenUsage?.sessionTokens == 1200)
        #expect(decoded.entries.first?.tokenUsage?.currencyCode == "EUR")
        #expect(decoded.entries.first?.tokenUsage?.sessionLabel == "Latest billing day")
        #expect(decoded.entries.first?.tokenUsage?.last30DaysLabel == "This month")
        #expect(decoded.entries.first?.usageRows?.map(\.id) == ["session", "weekly"])
        #expect(decoded.entries.first?.quotaOwnerKey == "claude-account-cache-key")
        #expect(decoded.enabledProviders == [.codex, .claude])
        #expect(decoded.usageBarsShowUsed)
    }

    @Test
    func `widget snapshot decodes legacy payload without usage rows`() throws {
        let json = """
        {
          "entries": [
            {
              "provider": "codex",
              "updatedAt": "2026-04-04T06:30:00Z",
              "primary": null,
              "secondary": {
                "usedPercent": 25,
                "windowMinutes": 10080,
                "resetsAt": null,
                "resetDescription": null
              },
              "tertiary": null,
              "creditsRemaining": null,
              "codeReviewRemainingPercent": null,
              "tokenUsage": null,
              "dailyUsage": []
            }
          ],
          "enabledProviders": ["codex"],
          "generatedAt": "2026-04-04T06:30:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))

        #expect(decoded.entries.count == 1)
        #expect(decoded.entries.first?.usageRows == nil)
        #expect(decoded.entries.first?.quotaOwnerKey == nil)
        #expect(decoded.entries.first?.secondary?.usedPercent == 25)
        #expect(!decoded.usageBarsShowUsed)
    }

    @Test
    func `widget snapshot decodes legacy token usage as usd`() throws {
        let json = """
        {
          "entries": [
            {
              "provider": "codex",
              "updatedAt": "2026-04-04T06:30:00Z",
              "primary": null,
              "secondary": null,
              "tertiary": null,
              "creditsRemaining": null,
              "codeReviewRemainingPercent": null,
              "tokenUsage": {
                "sessionCostUSD": 1.25,
                "sessionTokens": 1200,
                "last30DaysCostUSD": 9.50,
                "last30DaysTokens": 4200
              },
              "dailyUsage": []
            }
          ],
          "generatedAt": "2026-04-04T06:30:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))

        #expect(decoded.entries.first?.tokenUsage?.currencyCode == "USD")
        #expect(decoded.entries.first?.tokenUsage?.sessionLabel == "Today")
        #expect(decoded.entries.first?.tokenUsage?.last30DaysLabel == "30d")
        #expect(decoded.enabledProviders == [.codex])
    }

    @Test
    func `token usage summary round trips updatedAt and tolerates legacy payloads`() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let summary = WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: 1.5,
            sessionTokens: 100,
            last30DaysCostUSD: 30,
            last30DaysTokens: 2000,
            updatedAt: updatedAt)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            WidgetSnapshot.TokenUsageSummary.self,
            from: encoder.encode(summary))
        #expect(decoded.updatedAt == updatedAt)

        let legacy = try decoder.decode(
            WidgetSnapshot.TokenUsageSummary.self,
            from: Data(#"{"sessionCostUSD": 1.5, "sessionTokens": 100}"#.utf8))
        #expect(legacy.updatedAt == nil)
    }

    @Test
    func `token usage staleness discloses only meaningful lag`() {
        let entryUpdatedAt = Date()

        func summary(updatedAt: Date?) -> WidgetSnapshot.TokenUsageSummary {
            WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: nil,
                sessionTokens: nil,
                last30DaysCostUSD: nil,
                last30DaysTokens: nil,
                updatedAt: updatedAt)
        }

        #expect(!summary(updatedAt: entryUpdatedAt.addingTimeInterval(-5 * 60))
            .isStale(comparedTo: entryUpdatedAt))
        #expect(summary(updatedAt: entryUpdatedAt.addingTimeInterval(-61 * 60))
            .isStale(comparedTo: entryUpdatedAt))
        #expect(!summary(updatedAt: nil).isStale(comparedTo: entryUpdatedAt))
    }
}
