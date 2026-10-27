import BarsCore
import SwiftUI
import WidgetKit

extension WidgetTileSize {
    init(family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        default: self = .large
        }
    }
}

struct BarsUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BarsWidgetEntry

    var body: some View {
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider.instanceID }
        Group {
            if let providerEntry {
                UsageTile(entry: providerEntry, size: WidgetTileSize(family: self.family)) {
                    TileHeader(
                        provider: providerEntry.provider,
                        updatedAt: providerEntry.updatedAt,
                        size: WidgetTileSize(family: self.family))
                }
            } else {
                WidgetEmptyState(message: WidgetEmptyStateCopy.message(
                    provider: self.entry.provider,
                    snapshot: self.entry.snapshot))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
        .environment(\.widgetUsageShowsUsed, self.entry.snapshot.usageBarsShowUsed)
    }
}

struct BarsHistoryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BarsWidgetEntry

    var body: some View {
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider.instanceID }
        Group {
            if let providerEntry {
                HistoryView(entry: providerEntry, isLarge: self.family == .systemLarge)
            } else {
                WidgetEmptyState(message: WidgetEmptyStateCopy.message(
                    provider: self.entry.provider,
                    snapshot: self.entry.snapshot))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct BarsCompactWidgetView: View {
    let entry: BarsCompactEntry

    var body: some View {
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider.instanceID }
        Group {
            if let providerEntry {
                CompactMetricView(entry: providerEntry, metric: self.entry.metric)
            } else {
                WidgetEmptyState(message: WidgetEmptyStateCopy.message(
                    provider: self.entry.provider,
                    snapshot: self.entry.snapshot))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct BarsSwitcherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BarsSwitcherEntry

    var body: some View {
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider.instanceID }
        let size = WidgetTileSize(family: self.family)
        Group {
            if let providerEntry {
                UsageTile(entry: providerEntry, size: size) {
                    ProviderPagerHeader(
                        providers: self.entry.availableProviders,
                        selected: self.entry.provider,
                        updatedAt: providerEntry.updatedAt,
                        size: size)
                }
            } else {
                VStack(alignment: .leading, spacing: WidgetLayout.sectionSpacing) {
                    ProviderPagerHeader(
                        providers: self.entry.availableProviders,
                        selected: self.entry.provider,
                        updatedAt: Date(),
                        size: size)
                    WidgetEmptyState(message: WidgetEmptyStateCopy.switcherMessage(
                        provider: self.entry.provider,
                        snapshot: self.entry.snapshot))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
        .environment(\.widgetUsageShowsUsed, self.entry.snapshot.usageBarsShowUsed)
    }
}

private struct CompactMetricView: View {
    let entry: WidgetSnapshot.ProviderEntry
    let metric: CompactMetric

    var body: some View {
        let display = CompactMetricFormatter.display(for: self.entry, metric: self.metric)
        VStack(alignment: .leading, spacing: WidgetLayout.sectionSpacing) {
            TileHeader(provider: self.entry.provider, updatedAt: self.entry.updatedAt, size: .small)
            Spacer(minLength: 0)
            // This tile carries a single figure, so it gets the full width and sits centred rather
            // than clinging to the header with dead space underneath.
            HeroBlock(
                value: display.value,
                caption: WidgetFormat.tokenRowTitle(
                    display.label,
                    summary: self.metric == .credits ? nil : self.entry.tokenUsage,
                    entryUpdatedAt: self.entry.updatedAt),
                detail: (display.detail ?? CompactMetricFormatter.unavailableDetail(
                    value: display.value,
                    entry: self.entry))
                    .map { Text($0) },
                numberSize: WidgetLayout.compactMetricNumberSize)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CompactMetricDisplay: Equatable {
    let value: String
    let label: String
    let detail: String?
}

enum CompactMetricFormatter {
    static func display(for entry: WidgetSnapshot.ProviderEntry, metric: CompactMetric) -> CompactMetricDisplay {
        switch metric {
        case .credits:
            if let cost = WidgetBalanceFormatter.extraUsageCost(for: entry) {
                return CompactMetricDisplay(
                    value: WidgetFormat.currency(cost.used, code: cost.currencyCode),
                    label: W("Extra usage balance"),
                    detail: nil)
            }
            if let balance = WidgetBalanceFormatter.providerBalance(for: entry) {
                return CompactMetricDisplay(value: balance.value, label: balance.title, detail: nil)
            }
            let value = entry.creditsRemaining.map(WidgetFormat.credits) ?? "—"
            return CompactMetricDisplay(value: value, label: W("Credits left"), detail: nil)
        case .todayCost:
            let value = entry.tokenUsage.map { token in
                token.sessionCostUSD.map { WidgetFormat.currency($0, code: token.currencyCode) } ?? "—"
            } ?? "—"
            let detail = entry.tokenUsage?.sessionTokens.map(WidgetFormat.tokenCount)
            let label = entry.tokenUsage.map {
                Self.costMetricLabel($0.sessionLabel, provider: entry.provider)
            } ?? W("Today cost")
            return CompactMetricDisplay(value: value, label: label, detail: detail)
        case .last30DaysCost:
            let value = entry.tokenUsage.map { token in
                token.last30DaysCostUSD.map { WidgetFormat.currency($0, code: token.currencyCode) } ?? "—"
            } ?? "—"
            let detail = entry.tokenUsage?.last30DaysTokens.map(WidgetFormat.tokenCount)
            let label = entry.tokenUsage.map {
                Self.costMetricLabel($0.last30DaysLabel, provider: entry.provider)
            } ?? W("30d cost")
            return CompactMetricDisplay(value: value, label: label, detail: detail)
        }
    }

    /// A tile pinned to a metric its provider never reports would otherwise be a blank square. Name
    /// the provider so the reason is obvious and the widget can be reconfigured.
    static func unavailableDetail(value: String, entry: WidgetSnapshot.ProviderEntry) -> String? {
        guard value == WidgetFormat.unavailable else { return nil }
        let name = entry.provider.firstPartyProvider
            .flatMap { ProviderDefaults.metadata[$0]?.displayName }
            ?? entry.provider.rawValue.capitalized
        return W("Not reported by %@", String(describing: name))
    }

    static func costMetricLabel(_ label: String, provider _: ProviderInstanceID) -> String {
        W("%@ cost", self.localizedPeriod(label))
    }

    private static func localizedPeriod(_ label: String) -> String {
        if label.hasSuffix("d"), let days = Int(label.dropLast()) {
            return W("%dd", days)
        }
        return W(label)
    }
}

enum WidgetEmptyStateCopy {
    static func message(provider: UsageProvider, snapshot: WidgetSnapshot) -> String {
        guard !snapshot.enabledProviders.isEmpty else {
            return W("Enable a provider in bars → Settings → Providers.")
        }
        guard !snapshot.enabledProviders.contains(provider.instanceID) else { return W("No data") }
        let name = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue.capitalized
        return W("%@ is unavailable. Edit the widget to choose a provider.", name)
    }

    static func switcherMessage(provider: UsageProvider, snapshot: WidgetSnapshot) -> String {
        snapshot.enabledProviders.contains(provider.instanceID)
            ? W("No data") : W("Enable a provider in bars → Settings → Providers.")
    }
}

/// Header for the switcher widget: the selected provider spelled out in full, plus a pager to
/// move through the others.
///
/// A widget cannot open a menu or a picker, so paging is the control that fits: it costs one line
/// instead of a whole chip row, and the provider whose numbers are on screen is always named.
struct ProviderPagerHeader: View {
    let providers: [UsageProvider]
    let selected: UsageProvider
    let updatedAt: Date
    let size: WidgetTileSize

    var body: some View {
        let pager = ProviderPager.make(providers: self.providers, selected: self.selected)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                ProviderMark(provider: self.selected, isSelected: true, size: self.size.markSize)
                Text(ProviderTitle.text(for: self.selected, size: self.size))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(2)
                if self.size != .small {
                    FreshnessLabel(updatedAt: self.updatedAt)
                        .layoutPriority(0)
                }
                Spacer(minLength: 4)
                if let pager, pager.isPageable {
                    ProviderPagerControls(pager: pager, size: self.size)
                        .layoutPriority(1)
                }
            }
            if self.size == .small {
                FreshnessLabel(updatedAt: self.updatedAt)
            }
        }
    }
}

private struct ProviderPagerControls: View {
    let pager: ProviderPager
    let size: WidgetTileSize

    var body: some View {
        HStack(spacing: 3) {
            if self.size != .small {
                ProviderPageButton(provider: self.pager.previous, symbol: "chevron.left", size: self.size)
                Text(self.pager.positionText)
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            ProviderPageButton(provider: self.pager.next, symbol: "chevron.right", size: self.size)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(W("Provider %@", String(describing: self.pager.positionText))))
    }
}

private struct ProviderPageButton: View {
    @Environment(\.widgetProviderSelectionOverride) private var selectionOverride
    let provider: UsageProvider
    let symbol: String
    let size: WidgetTileSize

    var body: some View {
        if let choice = ProviderChoice(provider: self.provider) {
            Group {
                if let selectionOverride {
                    Button { selectionOverride(self.provider) } label: { self.glyph }
                } else {
                    Button(intent: SwitchWidgetProviderIntent(provider: choice)) { self.glyph }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(ProviderPageButtonLabel.text(for: self.provider)))
        } else {
            self.glyph.opacity(0.4)
        }
    }

    private var glyph: some View {
        let side = self.size.markSize - 2
        return Image(systemName: self.symbol)
            .font(.system(size: side * 0.44, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .fill(Color.primary.opacity(0.07)))
    }
}

enum ProviderPageButtonLabel {
    static func text(for provider: UsageProvider) -> String {
        let name = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue.capitalized
        return W("Switch to %@", String(describing: name))
    }
}

struct WidgetUsageRow: Identifiable, Equatable {
    let id: String
    let title: String
    let percentLeft: Double?
    /// Carried through from the row's rate window so tiles can show when the lane frees up; the
    /// snapshot has always had it and the widgets used to drop it.
    var resetsAt: Date?
    var resetDescription: String?

    static func smallWidgetRowLimit(for entry: WidgetSnapshot.ProviderEntry) -> Int? {
        self.widgetRowLimit(for: entry, family: .small)
    }

    static func mediumWidgetRowLimit(for entry: WidgetSnapshot.ProviderEntry) -> Int? {
        self.widgetRowLimit(for: entry, family: .medium)
    }

    private static func widgetRowLimit(
        for entry: WidgetSnapshot.ProviderEntry,
        family: ProviderWidgetFamily) -> Int?
    {
        guard let provider = entry.provider.firstPartyProvider else { return nil }
        return ProviderDescriptorRegistry.descriptor(for: provider).presentation.widgetRowLimit(
            rows: entry.usageRows,
            family: family)
    }

    static func rows(
        for entry: WidgetSnapshot.ProviderEntry,
        limit: Int? = nil,
        now: Date = Date()) -> [WidgetUsageRow]
    {
        // Provider-specific by design: DeepSeek exposes no quota denominator, so a 100% bar would be misleading.
        guard entry.provider != .deepseek else { return [] }
        let rows: [WidgetUsageRow]
        if let usageRows = entry.usageRows {
            rows = usageRows.map { row in
                // The generic snapshot writer stores only a percentage for the primary/secondary/
                // tertiary slots and leaves their reset on the entry's own windows, so recover it
                // here. Resolved reset only — the row keeps its own percentage.
                let reset = row.window ?? self.slotWindow(for: row.id, entry: entry)
                return WidgetUsageRow(
                    id: row.id,
                    title: row.title,
                    percentLeft: row.window?.remainingPercent ?? row.percentLeft,
                    resetsAt: reset?.resetsAt,
                    resetDescription: reset?.resetDescription)
            }
        } else {
            let metadata = entry.provider.firstPartyProvider.flatMap { ProviderDefaults.metadata[$0] }
            var defaultRows = [
                WidgetUsageRow(
                    id: "primary",
                    title: metadata?.sessionLabel ?? "Session",
                    percentLeft: entry.primary?.remainingPercent,
                    resetsAt: entry.primary?.resetsAt,
                    resetDescription: entry.primary?.resetDescription),
                WidgetUsageRow(
                    id: "secondary",
                    title: metadata?.weeklyLabel ?? "Weekly",
                    percentLeft: entry.secondary?.remainingPercent,
                    resetsAt: entry.secondary?.resetsAt,
                    resetDescription: entry.secondary?.resetDescription),
            ]
            if metadata?.supportsOpus == true {
                defaultRows.append(WidgetUsageRow(
                    id: "tertiary",
                    title: metadata?.opusLabel ?? "Opus",
                    percentLeft: entry.tertiary?.remainingPercent,
                    resetsAt: entry.tertiary?.resetsAt,
                    resetDescription: entry.tertiary?.resetDescription))
            }
            rows = defaultRows.filter { $0.percentLeft != nil }
        }
        guard let limit else { return rows }
        return Array(rows.prefix(max(0, limit)))
    }

    /// Reset metadata for the slot IDs the generic snapshot writer emits. Deliberately narrow:
    /// provider-specific row IDs carry their own window when the writer has one.
    static func slotWindow(for rowID: String, entry: WidgetSnapshot.ProviderEntry) -> RateWindow? {
        switch rowID {
        case "primary": entry.primary
        case "secondary": entry.secondary
        case "tertiary": entry.tertiary
        default: nil
        }
    }

    static func compactTokenUsage(
        for entry: WidgetSnapshot.ProviderEntry) -> WidgetSnapshot.TokenUsageSummary?
    {
        guard self.rows(for: entry).isEmpty,
              entry.codeReviewRemainingPercent == nil
        else {
            return nil
        }
        return entry.tokenUsage
    }

    private static func isMoreConstrained(_ lhs: WidgetUsageRow, than rhs: WidgetUsageRow) -> Bool {
        switch (lhs.percentLeft, rhs.percentLeft) {
        case let (.some(left), .some(right)):
            left < right
        case (.some, .none):
            true
        case (.none, .some):
            false
        case (.none, .none):
            false
        }
    }
}

enum WidgetUsageDisplay {
    static func percent(fromRemaining remaining: Double?, showUsed: Bool) -> Double? {
        guard let remaining else { return nil }
        let clamped = max(0, min(100, remaining))
        return showUsed ? 100 - clamped : clamped
    }
}

private struct HistoryView: View {
    let entry: WidgetSnapshot.ProviderEntry
    let isLarge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.sectionSpacing) {
            TileHeader(
                provider: self.entry.provider,
                updatedAt: self.entry.updatedAt,
                size: self.isLarge ? .large : .medium)
            UsageHistoryChart(
                points: self.entry.dailyUsage,
                color: WidgetColors.color(for: self.entry.provider),
                currencyCode: self.entry.tokenUsage?.currencyCode)
                .frame(minHeight: self.isLarge ? 110 : 58, maxHeight: .infinity)
            if let token = entry.tokenUsage {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetSeparator().padding(.bottom, 2)
                    MetricLine(
                        title: WidgetFormat.tokenRowTitle(
                            token.sessionLabel,
                            summary: token,
                            entryUpdatedAt: self.entry.updatedAt),
                        value: WidgetFormat.costAndTokens(
                            cost: token.sessionCostUSD,
                            tokens: token.sessionTokens,
                            currencyCode: token.currencyCode),
                        isProminent: true)
                    MetricLine(
                        title: WidgetFormat.tokenRowTitle(
                            token.last30DaysLabel,
                            summary: token,
                            entryUpdatedAt: self.entry.updatedAt),
                        value: WidgetFormat.costAndTokens(
                            cost: token.last30DaysCostUSD,
                            tokens: token.last30DaysTokens,
                            currencyCode: token.currencyCode))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Daily cost or token history. The chart now labels its peak and its date range, and the most
/// recent day is drawn at full strength so "where am I today" is answerable at a glance.
struct UsageHistoryChart: View {
    let points: [WidgetSnapshot.DailyUsagePoint]
    let color: Color
    let currencyCode: String?

    var body: some View {
        let isCostMode = UsageHistoryChartMode.isCostMode(self.points)
        let values = self.points.map { point -> Double in
            isCostMode ? (point.costUSD ?? 0) : Double(point.totalTokens ?? 0)
        }
        let scale = UsageChartScale(values: values)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(UsageHistoryChartCopy.title(dayCount: self.points.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let peak = UsageHistoryChartCopy.peak(
                    maximum: scale.maximum,
                    isCostMode: isCostMode,
                    currencyCode: self.currencyCode)
                {
                    Text(peak)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .allowsTightening(true)
                }
            }
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(values.indices, id: \.self) { index in
                        let fraction = scale.fraction(for: values[index])
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(self.color.opacity(index == values.indices.last ? 1 : 0.55))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(fraction > 0 ? 2 : 0, CGFloat(fraction) * geometry.size.height))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(maxHeight: .infinity)
            Rectangle()
                .fill(Color.primary.opacity(WidgetLayout.separatorOpacity))
                .frame(height: 1)
            if let range = UsageHistoryChartCopy.range(points: self.points) {
                HStack(spacing: 4) {
                    Text(range.start)
                    Spacer(minLength: 4)
                    Text(range.end)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
    }
}

enum UsageHistoryChartCopy {
    static func title(dayCount: Int) -> String {
        dayCount > 0 ? W("Last %d days", dayCount) : W("Daily usage")
    }

    static func peak(maximum: Double, isCostMode: Bool, currencyCode: String?) -> String? {
        guard maximum > 0 else { return nil }
        if isCostMode, let currencyCode {
            return W(
                "Peak %@",
                String(describing: UsageFormatter.compactCurrencyString(maximum, currencyCode: currencyCode)))
        }
        guard !isCostMode else { return nil }
        return W("Peak %@", String(describing: UsageFormatter.tokenCountString(Int(maximum))))
    }

    static func range(points: [WidgetSnapshot.DailyUsagePoint]) -> (start: String, end: String)? {
        guard let first = points.first?.dayKey,
              let last = points.last?.dayKey,
              let start = WidgetFormat.dayLabel(first),
              let end = WidgetFormat.dayLabel(last),
              start != end
        else { return nil }
        return (start, end)
    }
}

enum UsageHistoryChartMode {
    static func isCostMode(_ points: [WidgetSnapshot.DailyUsagePoint]) -> Bool {
        !points.isEmpty && points.allSatisfy { $0.costUSD != nil }
    }
}

enum WidgetColors {
    static func color(for instanceID: ProviderInstanceID) -> Color {
        guard let provider = instanceID.firstPartyProvider else { return .secondary }
        // The widget cannot read ~/.bars/config.json, so it resolves the user override from the
        // copy the app mirrors into the App Group.
        let color = ProviderAccentColors.sharedOverride(for: instanceID)
            ?? ProviderDescriptorRegistry.descriptor(for: provider).branding.widgetColor
        return Color(red: color.red, green: color.green, blue: color.blue)
    }
}

struct WidgetBalanceLine: Equatable {
    let title: String
    let value: String
}

enum WidgetBalanceFormatter {
    static func providerBalance(for entry: WidgetSnapshot.ProviderEntry) -> WidgetBalanceLine? {
        // Provider-specific by design: these providers publish their widget value through the balance-text field.
        guard entry.provider == .deepseek,
              let value = entry.balanceText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return WidgetBalanceLine(title: "Balance", value: value)
    }

    static func extraUsageCost(for entry: WidgetSnapshot.ProviderEntry) -> ProviderCostSnapshot? {
        // Provider-specific by design: Devin encodes its extra-usage balance as a named provider-cost period.
        guard entry.provider == .devin,
              let cost = entry.providerCost,
              cost.period == "Extra usage balance"
        else { return nil }
        return cost
    }

    static func extraUsageBalance(for entry: WidgetSnapshot.ProviderEntry) -> WidgetBalanceLine? {
        guard let cost = self.extraUsageCost(for: entry) else { return nil }
        return WidgetBalanceLine(
            title: "Extra usage",
            value: W("%@: %@", W("Balance"), WidgetFormat.currency(cost.used, code: cost.currencyCode)))
    }
}

enum WidgetFormat {
    /// Shown when a provider does not report a figure at all.
    static let unavailable = "—"

    static func percent(_ value: Double?) -> String {
        guard let value else { return self.unavailable }
        return String(format: "%.0f%%", value)
    }

    static func credits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    static func costAndTokens(cost: Double?, tokens: Int?, currencyCode: String = "USD") -> String {
        let costText = cost.map { self.currency($0, code: currencyCode) } ?? self.unavailable
        if let tokens {
            return "\(costText) · \(self.tokenCount(tokens))"
        }
        return costText
    }

    static func currency(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(code) \(String(format: "%.2f", value))"
    }

    static func tokenCount(_ value: Int) -> String {
        "\(UsageFormatter.tokenCountString(value)) tokens"
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// "2026-08-12" to "Aug 12". Returns nil for keys the chart cannot date.
    static func dayLabel(_ dayKey: String) -> String? {
        guard let date = self.dayKeyFormatter.date(from: dayKey) else { return nil }
        return self.dayLabelFormatter.string(from: date)
    }

    /// Suffixes the title with the token snapshot's own age once it lags the entry's
    /// freshness signal past `TokenUsageSummary.staleLagThreshold`.
    static func tokenRowTitle(
        _ base: String,
        summary: WidgetSnapshot.TokenUsageSummary?,
        entryUpdatedAt: Date) -> Text
    {
        guard let summary, summary.isStale(comparedTo: entryUpdatedAt), let updatedAt = summary.updatedAt else {
            return Text(W(base))
        }
        return Text("\(W(base)) · \(WidgetDateText.offset(updatedAt))")
    }
}
