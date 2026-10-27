import AppIntents
import BarsCore
import SwiftUI
import WidgetKit

enum ProviderChoice: String, AppEnum {
    case claude
    case devin
    case opencode
    case opencodego
    case deepseek

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")

    /// AppIntents extracts this metadata statically; it must stay a literal, exhaustive
    /// dictionary. WidgetProviderChoiceTests pins these titles to the descriptor registry.
    /// Provider-specific by design: AppIntents requires a compile-time provider display inventory.
    static let caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .claude: DisplayRepresentation(title: "Claude"),
        .devin: DisplayRepresentation(title: "Devin"),
        .opencode: DisplayRepresentation(title: "OpenCode"),
        .opencodego: DisplayRepresentation(title: "OpenCode Go"),
        .deepseek: DisplayRepresentation(title: "DeepSeek"),
    ]

    var provider: UsageProvider {
        UsageProvider(rawValue: self.rawValue)!
    }

    init?(provider: UsageProvider) {
        guard ProviderDescriptorRegistry.descriptor(for: provider).metadata.widgetSelectable else { return nil }
        self.init(rawValue: provider.rawValue)
    }
}

enum CompactMetric: String, AppEnum {
    case credits
    case todayCost
    case last30DaysCost

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Metric")

    static let caseDisplayRepresentations: [CompactMetric: DisplayRepresentation] = [
        .credits: DisplayRepresentation(title: "Credits left"),
        .todayCost: DisplayRepresentation(title: "Today cost"),
        .last30DaysCost: DisplayRepresentation(title: "Cost"),
    ]
}

struct ProviderSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider"
    static let description = IntentDescription("Select the provider to display in the widget.")

    @Parameter(title: "Provider", default: .claude)
    var provider: ProviderChoice

    init() {
        self.provider = .claude
    }
}

struct SwitchWidgetProviderIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Provider"
    static let description = IntentDescription("Switch the provider shown in the widget.")

    @Parameter(title: "Provider")
    var provider: ProviderChoice

    init() {}

    init(provider: ProviderChoice) {
        self.provider = provider
    }

    func perform() async throws -> some IntentResult {
        WidgetSelectionStore.saveSelectedProvider(self.provider.provider)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct CompactMetricSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider + Metric"
    static let description = IntentDescription("Select the provider and metric to display.")

    @Parameter(title: "Provider", default: .claude)
    var provider: ProviderChoice

    @Parameter(title: "Metric", default: .credits)
    var metric: CompactMetric

    init() {
        self.provider = .claude
        self.metric = .credits
    }
}

struct BarsWidgetEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let snapshot: WidgetSnapshot
}

struct BarsCompactEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let metric: CompactMetric
    let snapshot: WidgetSnapshot
}

struct BarsSwitcherEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let availableProviders: [UsageProvider]
    let snapshot: WidgetSnapshot
}

struct BarsTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BarsWidgetEntry {
        BarsWidgetEntry(
            date: Date(),
            provider: .claude,
            snapshot: WidgetPreviewData.snapshot())
    }

    func snapshot(for configuration: ProviderSelectionIntent, in context: Context) async -> BarsWidgetEntry {
        let provider = configuration.provider.provider
        return BarsWidgetEntry(
            date: Date(),
            provider: provider,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot())
    }

    func timeline(
        for configuration: ProviderSelectionIntent,
        in context: Context) async -> Timeline<BarsWidgetEntry>
    {
        let provider = configuration.provider.provider
        let snapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot()
        let now = Date()
        let entry = BarsWidgetEntry(date: now, provider: provider, snapshot: snapshot)
        let refresh = BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: provider, now: now)
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}

struct BarsSwitcherTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BarsSwitcherEntry {
        let snapshot = WidgetPreviewData.snapshot()
        let providers = Self.supportedProviders(from: snapshot)
        return BarsSwitcherEntry(
            date: Date(),
            provider: providers.first ?? .claude,
            availableProviders: providers,
            snapshot: snapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (BarsSwitcherEntry) -> Void) {
        completion(self.makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BarsSwitcherEntry>) -> Void) {
        let entry = self.makeEntry()
        let refresh = BurnDownRefreshSchedule.nextRefresh(
            snapshot: entry.snapshot,
            provider: entry.provider,
            now: entry.date)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func makeEntry() -> BarsSwitcherEntry {
        let snapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot()
        let providers = Self.supportedProviders(from: snapshot)
        let stored = WidgetSelectionStore.loadSelectedProvider()
        let selected = providers.first { $0.instanceID == stored } ?? providers.first ?? .claude
        if selected.instanceID != stored {
            WidgetSelectionStore.saveSelectedProvider(selected)
        }
        return BarsSwitcherEntry(
            date: Date(),
            provider: selected,
            availableProviders: providers,
            snapshot: snapshot)
    }

    static func supportedProviders(from snapshot: WidgetSnapshot) -> [UsageProvider] {
        let enabled = snapshot.enabledProviders
        let instanceIDs = enabled.isEmpty ? snapshot.entries.map(\.provider) : enabled
        let supported = instanceIDs.compactMap { instanceID -> UsageProvider? in
            guard let provider = instanceID.firstPartyProvider, ProviderChoice(provider: provider) != nil else {
                return nil
            }
            return provider
        }
        return supported.isEmpty ? [.claude] : supported
    }
}

struct BarsCompactTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BarsCompactEntry {
        BarsCompactEntry(
            date: Date(),
            provider: .claude,
            metric: .credits,
            snapshot: WidgetPreviewData.snapshot())
    }

    func snapshot(for configuration: CompactMetricSelectionIntent, in context: Context) async -> BarsCompactEntry {
        let provider = configuration.provider.provider
        let metric = configuration.metric
        return BarsCompactEntry(
            date: Date(),
            provider: provider,
            metric: metric,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot())
    }

    func timeline(
        for configuration: CompactMetricSelectionIntent,
        in context: Context) async -> Timeline<BarsCompactEntry>
    {
        let provider = configuration.provider.provider
        let metric = configuration.metric
        let snapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot()
        let entry = BarsCompactEntry(
            date: Date(),
            provider: provider,
            metric: metric,
            snapshot: snapshot)
        let refresh = Date().addingTimeInterval(30 * 60)
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}

enum WidgetPreviewData {
    static func emptySnapshot() -> WidgetSnapshot {
        WidgetSnapshot(entries: [], enabledProviders: [], generatedAt: Date())
    }

    static func snapshot() -> WidgetSnapshot {
        let now = Date()
        let primary = RateWindow(
            usedPercent: 35,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(4 * 3600),
            resetDescription: "Resets in 4h")
        let secondary = RateWindow(
            usedPercent: 60,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(3 * 86400),
            resetDescription: "Resets in 3d")
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: now,
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            creditsRemaining: 1243.4,
            codeReviewRemainingPercent: 78,
            tokenUsage: WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: 12.4,
                sessionTokens: 420_000,
                last30DaysCostUSD: 923.8,
                last30DaysTokens: 12_400_000),
            dailyUsage: [
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-01", totalTokens: 120_000, costUSD: 15.2),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-02", totalTokens: 80000, costUSD: 10.1),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-03", totalTokens: 140_000, costUSD: 17.9),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-04", totalTokens: 90000, costUSD: 11.4),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-05", totalTokens: 160_000, costUSD: 19.8),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-06", totalTokens: 70000, costUSD: 8.9),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-07", totalTokens: 110_000, costUSD: 13.7),
            ])
        return WidgetSnapshot(entries: [entry], generatedAt: now)
    }
}
