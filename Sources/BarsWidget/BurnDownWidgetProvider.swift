import AppIntents
import BarsCore
import WidgetKit

/// Provider-specific by design: AppIntents requires compile-time enum cases and display representations;
/// runtime presentation policy still comes from each provider descriptor below this literal WidgetKit surface.
enum BurnProviderChoice: String, AppEnum {
    case claude
    case devin
    case opencode
    case opencodego
    case deepseek
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")

    static let caseDisplayRepresentations: [BurnProviderChoice: DisplayRepresentation] = [
        // Provider-specific by design: AppIntents requires literal catalog titles; snapshot data gates eligibility.
        .claude: DisplayRepresentation(title: "Claude"),
        .opencode: DisplayRepresentation(title: "OpenCode"),
        .opencodego: DisplayRepresentation(title: "OpenCode Go"),
        .devin: DisplayRepresentation(title: "Devin"),
        // Provider-specific by design: AppIntents requires literal catalog titles; snapshot data gates eligibility.
        .deepseek: DisplayRepresentation(title: "DeepSeek"),
    ]

    var provider: UsageProvider {
        UsageProvider(rawValue: self.rawValue)!
    }
}

enum BurnWindowChoice: String, AppEnum {
    case session
    case weekly
    case primary
    case secondary
    case tertiary

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Usage window")

    static let caseDisplayRepresentations: [BurnWindowChoice: DisplayRepresentation] = [
        .session: DisplayRepresentation(title: "Session (5-hour)"),
        .weekly: DisplayRepresentation(title: "Weekly (7-day)"),
        .primary: DisplayRepresentation(title: "Primary quota"),
        .secondary: DisplayRepresentation(title: "Secondary quota"),
        .tertiary: DisplayRepresentation(title: "Third quota"),
    ]
}

struct BurnDownSelectionIntent: AppIntent, WidgetConfigurationIntent {
    // Provider-specific by design: the burn-down widget defaults to Claude session usage.
    static let title: LocalizedStringResource = "Burn Down"
    static let description = IntentDescription("Select the provider and usage window to display.")

    @Parameter(title: "Provider", default: .claude, optionsProvider: BurnProviderOptions())
    var provider: BurnProviderChoice

    @Parameter(title: "Usage window", default: .session, optionsProvider: BurnWindowOptions())
    var window: BurnWindowChoice

    init() {
        self.provider = .claude
        self.window = .session
    }
}

struct BurnProviderSelectionIntent: AppIntent, WidgetConfigurationIntent {
    // Provider-specific by design: the provider-only burn-down widget also defaults to Claude.
    static let title: LocalizedStringResource = "Burn Down Provider"
    static let description = IntentDescription("Select the provider to display.")

    @Parameter(title: "Provider", default: .claude, optionsProvider: BurnProviderOptions(combined: true))
    var provider: BurnProviderChoice

    init() {
        self.provider = .claude
    }
}

struct BurnDownEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let window: BurnWindowChoice
    let snapshot: WidgetSnapshot
}

struct CombinedBurnDownEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let snapshot: WidgetSnapshot
}

struct BurnProviderOptions: DynamicOptionsProvider {
    var combined = false

    func results() async throws -> [BurnProviderChoice] {
        Self.choices(in: WidgetSnapshotStore.load(), combined: self.combined)
    }

    static func choices(in snapshot: WidgetSnapshot?, combined: Bool = false) -> [BurnProviderChoice] {
        guard let snapshot else { return [] }
        return BurnProviderChoice.allCases.filter { choice in
            guard ProviderDescriptorRegistry.descriptor(for: choice.provider).metadata.burnDownWidgetSelectable,
                  snapshot.enabledProviders.contains(choice.provider.instanceID),
                  let state = BurnDownState(snapshot: snapshot, provider: choice.provider, selection: .primary)
            else { return false }
            let selections = combined ? state.combinedSelections : state.availableSelections
            return selections.contains { state.window(for: $0) != nil }
        }
    }
}

struct BurnWindowOptions: DynamicOptionsProvider {
    @IntentParameterDependency<BurnDownSelectionIntent>(\.$provider)
    var intent

    func results() async throws -> ItemCollection<BurnWindowChoice> {
        guard let provider = self.intent?.provider.provider,
              let snapshot = WidgetSnapshotStore.load(),
              let state = BurnDownState(snapshot: snapshot, provider: provider, selection: .primary)
        else { return .empty }
        return ItemCollection(sections: [.init(items: state.availableSelections.map { selection in
            IntentItem(selection, title: "\(state.title(for: selection))")
        })])
    }
}

struct BurnDownState {
    let entry: WidgetSnapshot.ProviderEntry
    let selection: BurnWindowChoice
    let now: Date

    init?(
        snapshot: WidgetSnapshot,
        provider: UsageProvider,
        selection: BurnWindowChoice,
        now: Date = Date())
    {
        guard ProviderDescriptorRegistry.descriptor(for: provider).metadata.burnDownWidgetSelectable,
              let entry = snapshot.entries.first(where: { $0.provider == provider.instanceID }) else { return nil }
        self.entry = entry
        self.selection = selection
        self.now = now
    }

    static func isCompatible(_ window: RateWindow?) -> Bool {
        guard let window, window.usedPercent.isFinite, !window.isSyntheticPlaceholder,
              let minutes = window.windowMinutes, minutes > 0,
              let reset = window.resetsAt, reset.timeIntervalSince1970.isFinite else { return false }
        return true
    }

    /// Provider-specific by design: preserve the two original Combined intent lane identities on upgrade.
    var usesLegacyLanes: Bool {
        self.entry.provider == UsageProvider.claude.instanceID
    }

    var availableSelections: [BurnWindowChoice] {
        let choices: [BurnWindowChoice] = self.combinedSelections == [.session, .weekly]
            ? [.session, .weekly, .tertiary] : [.primary, .secondary, .tertiary]
        return choices.filter { self.window(for: $0) != nil }
    }

    var combinedSelections: [BurnWindowChoice] {
        let legacyShape = [self.entry.primary, self.entry.secondary].compactMap(\.self).allSatisfy {
            $0.windowMinutes == nil || $0.windowMinutes == 300 || $0.windowMinutes == 10080
        }
        return self.usesLegacyLanes && legacyShape ? [.session, .weekly] : [.primary, .secondary]
    }

    func title(for selection: BurnWindowChoice) -> String {
        let metadata = self.entry.provider.firstPartyProvider.flatMap { ProviderDefaults.metadata[$0] }
        switch selection {
        case .session: return W("Session")
        case .weekly: return W("Weekly")
        case .primary, .secondary, .tertiary:
            let title = self.entry.usageRows?.first { $0.id == selection.rawValue }?.title
                ?? (selection == .primary ? metadata?.sessionLabel
                    : selection == .secondary ? metadata?.weeklyLabel : metadata?.opusLabel)
                ?? "Usage"
            return W(title)
        }
    }

    var selectedTitle: String {
        self.title(for: self.selection)
    }

    var secondaryGloballyCapsPrimary: Bool {
        guard let provider = self.entry.provider.firstPartyProvider else { return false }
        return ProviderDescriptorRegistry.descriptor(for: provider).presentation.secondaryGloballyCapsPrimary
    }

    var secondaryExhausted: Bool {
        // A known exhausted cap still blocks usage when its reset is unavailable for charting.
        guard self.secondaryGloballyCapsPrimary, let secondary = self.sourceWindow(for: .weekly),
              secondary.usedPercent.isFinite, !secondary.isSyntheticPlaceholder else { return false }
        return secondary.remainingPercent <= 0 && (secondary.resetsAt.map { $0 > self.now } ?? true)
    }

    var primaryWindow: RateWindow? {
        self.window(for: .session)
    }

    var secondaryWindow: RateWindow? {
        self.rawWindow(for: .weekly)
    }

    var selectedWindow: RateWindow? {
        self.window(for: self.selection)
    }

    func blanksChart(for selection: BurnWindowChoice) -> Bool {
        guard selection == .session || selection == .primary,
              self.secondaryExhausted, let window = self.rawWindow(for: selection) else { return false }
        return window.windowMinutes != 10080
    }

    var blankPrimaryChart: Bool {
        self.blanksChart(for: self.selection)
    }

    var selectedResetOverride: Date? {
        self.blankPrimaryChart ? self.secondaryWindow?.resetsAt : nil
    }

    func window(for selection: BurnWindowChoice) -> RateWindow? {
        guard let window = self.rawWindow(for: selection) else { return nil }
        guard self.blanksChart(for: selection), window.remainingPercent > 0 else { return window }
        return RateWindow(
            usedPercent: 100,
            windowMinutes: window.windowMinutes,
            resetsAt: window.resetsAt,
            resetDescription: window.resetDescription,
            nextRegenPercent: window.nextRegenPercent)
    }

    private func rawWindow(for selection: BurnWindowChoice) -> RateWindow? {
        let window = self.sourceWindow(for: selection)
        return Self.isCompatible(window) ? window : nil
    }

    private func sourceWindow(for selection: BurnWindowChoice) -> RateWindow? {
        switch selection {
        case .session, .weekly:
            // Keep the persisted duration-based choices exact; never borrow a different lane.
            [self.entry.primary, self.entry.secondary].compactMap(\.self)
                .first { $0.windowMinutes == (selection == .session ? 300 : 10080) }
        case .primary: self.entry.primary
        case .secondary: self.entry.secondary
        case .tertiary: self.entry.tertiary
        }
    }
}

enum BurnDownRefreshSchedule {
    private static let minimumInterval: TimeInterval = 5 * 60
    private static let maximumInterval: TimeInterval = 30 * 60

    static func nextRefresh(
        snapshot: WidgetSnapshot,
        provider: UsageProvider,
        now: Date = Date()) -> Date
    {
        let fallback = now.addingTimeInterval(self.maximumInterval)
        guard let entry = snapshot.entries.first(where: { $0.provider == provider.instanceID }) else { return fallback }
        let nextReset = [entry.primary?.resetsAt, entry.secondary?.resetsAt, entry.tertiary?.resetsAt]
            .compactMap(\.self)
            .filter { $0 > now }
            .min()?
            .addingTimeInterval(1)
        if let nextReset {
            let target = min(fallback, nextReset)
            let minimumDate = now.addingTimeInterval(self.minimumInterval)
            return max(minimumDate, target)
        }
        return fallback
    }
}

struct BurnDownTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BurnDownEntry {
        BurnDownEntry(
            date: Date(),
            provider: .claude,
            window: .session,
            snapshot: WidgetPreviewData.snapshot())
    }

    func snapshot(for configuration: BurnDownSelectionIntent, in context: Context) async -> BurnDownEntry {
        BurnDownEntry(
            date: Date(),
            provider: configuration.provider.provider,
            window: configuration.window,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot())
    }

    func timeline(
        for configuration: BurnDownSelectionIntent,
        in context: Context) async -> Timeline<BurnDownEntry>
    {
        let entry = BurnDownEntry(
            date: Date(),
            provider: configuration.provider.provider,
            window: configuration.window,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot())
        let refresh = BurnDownRefreshSchedule.nextRefresh(snapshot: entry.snapshot, provider: entry.provider)
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}

struct CombinedBurnDownTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CombinedBurnDownEntry {
        CombinedBurnDownEntry(
            date: Date(),
            provider: .claude,
            snapshot: WidgetPreviewData.snapshot())
    }

    func snapshot(
        for configuration: BurnProviderSelectionIntent,
        in context: Context) async -> CombinedBurnDownEntry
    {
        CombinedBurnDownEntry(
            date: Date(),
            provider: configuration.provider.provider,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot())
    }

    func timeline(
        for configuration: BurnProviderSelectionIntent,
        in context: Context) async -> Timeline<CombinedBurnDownEntry>
    {
        let entry = CombinedBurnDownEntry(
            date: Date(),
            provider: configuration.provider.provider,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot())
        let refresh = BurnDownRefreshSchedule.nextRefresh(snapshot: entry.snapshot, provider: entry.provider)
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}
