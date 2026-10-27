import Foundation
import Testing
@testable import BarsCore
@testable import BarsWidget

@MainActor
struct WidgetEmptyStateCopyTests {
    @Test
    func `default widget entry names disabled Claude without changing its pin`() {
        let snapshot = WidgetSnapshot(entries: [], enabledProviders: [.opencode, .deepseek], generatedAt: Date())
        let entry = BarsWidgetEntry(
            date: snapshot.generatedAt, provider: ProviderSelectionIntent().provider.provider, snapshot: snapshot)
        WidgetLocalizationOverride.$language.withValue("en") {
            #expect(WidgetEmptyStateCopy.message(provider: entry.provider, snapshot: entry.snapshot) ==
                "Claude is unavailable. Edit the widget to choose a provider.")
        }
        #expect(entry.provider == .claude)
        let metric = CompactMetricSelectionIntent()
        #expect(WidgetEmptyStateCopy.message(provider: metric.provider.provider, snapshot: snapshot) ==
            WidgetEmptyStateCopy.message(provider: entry.provider, snapshot: snapshot))
        #expect(WidgetEmptyStateCopy.message(provider: .opencode, snapshot: snapshot) == W("No data"))
    }

    @Test
    func `empty and legacy snapshots point at provider setup`() throws {
        let legacy = try JSONDecoder().decode(
            WidgetSnapshot.self,
            from: Data(#"{"version":1,"generatedAt":0,"entries":[],"usageBarsShowUsed":true}"#.utf8))
        for snapshot in [legacy, WidgetPreviewData.emptySnapshot()] {
            #expect(WidgetEmptyStateCopy.message(provider: .opencode, snapshot: snapshot) ==
                W("Enable a provider in bars → Settings → Providers."))
        }
    }
}
