import SwiftUI
import WidgetKit

@main
struct BarsWidgetBundle: WidgetBundle {
    var body: some Widget {
        BarsSwitcherWidget()
        BarsUsageWidget()
        BarsHistoryWidget()
        BarsCompactWidget()
        BarsBurnDownWidget()
        BarsCombinedBurnDownWidget()
        BarsAccountUsageWidget()
        BarsAccountsWidget()
    }
}

struct BarsSwitcherWidget: Widget {
    private let kind = "BarsSwitcherWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: self.kind,
            provider: BarsSwitcherTimelineProvider())
        { entry in
            BarsSwitcherWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(W("bars Switcher")))
        .description(Text(W("Usage widget with a provider switcher.")))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct BarsUsageWidget: Widget {
    private let kind = "BarsUsageWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: ProviderSelectionIntent.self,
            provider: BarsTimelineProvider())
        { entry in
            BarsUsageWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(W("bars Usage")))
        .description(Text(W("Session and weekly usage with credits and costs.")))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct BarsHistoryWidget: Widget {
    private let kind = "BarsHistoryWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: ProviderSelectionIntent.self,
            provider: BarsTimelineProvider())
        { entry in
            BarsHistoryWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(W("bars History")))
        .description(Text(W("Usage history chart with recent totals.")))
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct BarsCompactWidget: Widget {
    private let kind = "BarsCompactWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: CompactMetricSelectionIntent.self,
            provider: BarsCompactTimelineProvider())
        { entry in
            BarsCompactWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(W("bars Metric")))
        .description(Text(W("Compact widget for credits or cost.")))
        .supportedFamilies([.systemSmall])
    }
}

enum BurnDownWidgetBackgroundConfiguration {
    static let isRemovable = true
}

struct BarsBurnDownWidget: Widget {
    private let kind = "BarsBurnDownWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: BurnDownSelectionIntent.self,
            provider: BurnDownTimelineProvider())
        { entry in
            BurnDownWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(W("bars Burn Down")))
        .description(Text(W("Remaining budget compared with an ideal steady burn rate.")))
        .supportedFamilies([.systemMedium])
        .containerBackgroundRemovable(BurnDownWidgetBackgroundConfiguration.isRemovable)
    }
}

struct BarsCombinedBurnDownWidget: Widget {
    private let kind = "BarsCombinedBurnDownWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: BurnProviderSelectionIntent.self,
            provider: CombinedBurnDownTimelineProvider())
        { entry in
            CombinedBurnDownWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(W("bars Burn Down (Combined)")))
        .description(Text(W("Two quota burn-down charts in one tile.")))
        .supportedFamilies([.systemMedium])
        .containerBackgroundRemovable(BurnDownWidgetBackgroundConfiguration.isRemovable)
    }
}
