import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarWidget

struct ProviderWidgetAvailabilityTests {
    @Test
    func `DeepSeek balance does not render as a quota bar`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .deepseek,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: "$15.00"),
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            balanceText: "$15.00")

        #expect(WidgetUsageRow.rows(for: entry).isEmpty)
    }

    @Test
    func `provider balance survives snapshot JSON round trip`() throws {
        let snapshot = WidgetSnapshot(
            entries: [Self.entry(provider: .deepseek, balanceText: "$15.25")],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))

        #expect(decoded.entries.first?.provider == .deepseek)
        #expect(decoded.entries.first?.balanceText == "$15.25")
    }

    @Test
    func `legacy snapshot JSON without provider balance remains decodable`() throws {
        let snapshot = WidgetSnapshot(
            entries: [Self.entry(provider: .claude, balanceText: nil)],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let entries = object?["entries"] as? [[String: Any]]

        #expect(entries?.first?["balanceText"] == nil)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: encoded)
        #expect(decoded.entries.first?.provider == .claude)
        #expect(decoded.entries.first?.balanceText == nil)
    }

    private static func entry(
        provider: UsageProvider,
        balanceText: String?) -> WidgetSnapshot.ProviderEntry
    {
        WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            balanceText: balanceText)
    }
}

@MainActor
struct ProviderWidgetSnapshotTests {}
