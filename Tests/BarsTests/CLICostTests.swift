import BarsCore
import Commander
import Foundation
import Testing
@testable import BarsCLI

struct CLICostTests {
    @Test
    func `cost json shortcut does not enable json logs`() throws {
        let signature = BarsCLI._costSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--json"])

        #expect(parsed.flags.contains("jsonShortcut"))
        #expect(!parsed.flags.contains("jsonOutput"))
        #expect(BarsCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func `Claude breakdown is explicit opt in`() throws {
        let parser = CommandParser(signature: BarsCLI._costSignatureForTesting())

        let defaultValues = try parser.parse(arguments: [])
        #expect(!defaultValues.flags.contains("breakdown"))

        let breakdownValues = try parser.parse(arguments: ["--breakdown"])
        #expect(breakdownValues.flags.contains("breakdown"))
    }

    @Test
    func `OpenCode Go text breakdown preserves unknown costs and model tokens`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 125,
            sessionCostUSD: nil,
            last30DaysTokens: 125,
            last30DaysCostUSD: nil,
            historyDays: 1,
            daily: [.init(
                date: "1970-01-01",
                inputTokens: 100,
                outputTokens: 25,
                totalTokens: 125,
                costUSD: nil,
                modelsUsed: ["fixture-model"],
                modelBreakdowns: [.init(modelName: "fixture-model", costUSD: nil, totalTokens: 125)])],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = BarsCLI.renderCostText(
            provider: .opencodego, snapshot: snapshot, useColor: false, includeBreakdown: true)
        #expect(output.hasPrefix("OpenCode Go Cost (API-rate estimate)\n"))
        #expect(output.contains("Estimated from local OpenCode history · may differ from your bill"))
        #expect(output.contains("Daily breakdown"))
        #expect(output.contains("fixture-model"))
        #expect(output.contains("125 tokens"))
        #expect(!output.contains("$0.00"))
    }

    @Test
    func `session grouping does not change cost JSON payload`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.01,
            last30DaysTokens: 40,
            last30DaysCostUSD: 0.04,
            daily: [],
            sessions: [
                CostUsageSessionBreakdown(
                    sessionID: "abcd12345678abcd12345678abcd12345678",
                    lastActivity: Date(timeIntervalSince1970: 1_750_000_000),
                    inputTokens: 30,
                    cachedInputTokens: nil,
                    outputTokens: 10,
                    totalTokens: 40,
                    requestCount: 2,
                    costUSD: 0.04,
                    modelBreakdowns: []),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let payload = BarsCLI.makeCostPayload(provider: .opencode, snapshot: snapshot, error: nil)
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode cost payload JSON")
            return
        }

        #expect(!json.contains("\"sessions\""))
    }

    @Test(arguments: [
        (1200, 9000, "1.2K", "9K"),
        (999_999, 999_999_999, "1M", "1B"),
    ])
    func `renders cost text snapshot`(
        sessionTokens: Int,
        historyTokens: Int,
        sessionText: String,
        historyText: String)
    {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: sessionTokens,
            sessionCostUSD: 1.25,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: 9.99,
            historyDays: 90,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = BarsCLI.renderCostText(provider: .claude, snapshot: snap, useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output.contains("Claude Cost (API-rate estimate)"))
        #expect(output.contains("Today: $1.25 · \(sessionText) tokens"))
        #expect(output.contains("Last 90 days: $9.99 · \(historyText) tokens"))
        #expect(output.contains("cache read/write tokens"))
        #expect(output.contains("Claude Code /status"))
    }

    @Test
    func `encodes cost payload JSON`() throws {
        let payload = CostPayload(
            provider: "claude",
            source: "local",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionTokens: 100,
            sessionCostUSD: 0.5,
            historyDays: 90,
            last30DaysTokens: 200,
            last30DaysCostUSD: 1.5,
            daily: [
                CostDailyEntryPayload(
                    date: "2025-12-20",
                    inputTokens: 10,
                    outputTokens: 5,
                    cacheReadTokens: 2,
                    cacheCreationTokens: 3,
                    totalTokens: 15,
                    costUSD: 0.01,
                    modelsUsed: ["claude-sonnet-4-20250514"],
                    modelBreakdowns: [
                        CostModelBreakdownPayload(
                            modelName: "claude-sonnet-4-20250514",
                            costUSD: 0.01,
                            totalTokens: 15),
                    ]),
            ],
            totals: CostTotalsPayload(
                totalInputTokens: 10,
                totalOutputTokens: 5,
                cacheReadTokens: 2,
                cacheCreationTokens: 3,
                totalTokens: 15,
                totalCostUSD: 0.01),
            error: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode cost payload JSON")
            return
        }

        #expect(json.contains("\"provider\":\"claude\""))
        #expect(json.contains("\"source\":\"local\""))
        #expect(json.contains("\"historyDays\":90"))
        #expect(json.contains("\"daily\""))
        #expect(json.contains("\"totals\""))
        #expect(json.contains("\"cacheReadTokens\":2"))
        #expect(json.contains("\"cacheCreationTokens\":3"))
        #expect(json.contains("\"totalCost\""))
        #expect(json.contains("\"totalTokens\":15"))
        #expect(json.contains("1700000000"))
    }

    @Test
    func `cost JSON exposes history coverage as a boolean`() throws {
        for coverage in [false, true] {
            let snapshot = CostUsageTokenSnapshot(
                sessionTokens: 10,
                sessionCostUSD: 0.01,
                last30DaysTokens: 40,
                last30DaysCostUSD: 0.04,
                historyCoverageIsEstablished: coverage,
                daily: [],
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let payload = BarsCLI.makeCostPayload(provider: .opencode, snapshot: snapshot, error: nil)
            let data = try JSONEncoder().encode(payload)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

            #expect(object.keys.contains("historyCoverageIsEstablished"))
            #expect(object["historyCoverageIsEstablished"] as? Bool == coverage)
        }
    }

    @Test
    func `encodes exact codex model I ds and zero cost breakdowns`() throws {
        let payload = CostPayload(
            provider: "codex",
            source: "local",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionTokens: 155,
            sessionCostUSD: 0,
            historyDays: 30,
            last30DaysTokens: 155,
            last30DaysCostUSD: 0,
            daily: [
                CostDailyEntryPayload(
                    date: "2025-12-21",
                    inputTokens: 120,
                    outputTokens: 15,
                    cacheReadTokens: 20,
                    cacheCreationTokens: nil,
                    totalTokens: 155,
                    costUSD: 0,
                    modelsUsed: ["gpt-5.3-codex-spark", "gpt-5.2-codex"],
                    modelBreakdowns: [
                        CostModelBreakdownPayload(modelName: "gpt-5.3-codex-spark", costUSD: 0, totalTokens: 15),
                        CostModelBreakdownPayload(modelName: "gpt-5.2-codex", costUSD: 1.23, totalTokens: 140),
                    ]),
            ],
            totals: CostTotalsPayload(
                totalInputTokens: 120,
                totalOutputTokens: 15,
                cacheReadTokens: 20,
                cacheCreationTokens: nil,
                totalTokens: 155,
                totalCostUSD: 0),
            error: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode cost payload JSON")
            return
        }

        #expect(json.contains("\"gpt-5.3-codex-spark\""))
        #expect(json.contains("\"gpt-5.2-codex\""))
        #expect(!json.contains("\"gpt-5.2\""))
        #expect(json.contains("\"cost\":0"))
        #expect(json.contains("\"totalTokens\":140"))
    }

    @Test
    func `cost estimate hint is stable string`() {
        let hint = UsageFormatter.costEstimateHint
        #expect(!hint.isEmpty)
        #expect(hint.contains("Estimated"))
        #expect(UsageFormatter.costEstimateHint(provider: .claude).contains("cache read/write tokens"))
    }
}

private func sessionTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "MMM d, HH:mm"
    return formatter.string(from: date)
}

private struct CursorCostSettingsTestError: LocalizedError {
    var errorDescription: String? {
        "Cursor settings resolution failed."
    }
}
