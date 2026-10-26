import CodexBarCore
import Foundation

enum MenuBarMetricWindowResolver {
    static func rateWindow(
        preference: MenuBarMetricPreference,
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        supportsAverage: Bool,
        now: Date = Date())
        -> RateWindow?
    {
        guard let snapshot else { return nil }
        let presentation = ProviderDescriptorRegistry.descriptor(for: provider).presentation
        let metric = preference.providerMetric
        switch presentation.menuBarWindow(context: ProviderMenuBarWindowContext(
            metric: metric,
            snapshot: snapshot,
            supportsAverage: supportsAverage,
            prioritizesExhaustedQuotas: false,
            now: now))
        {
        case let .resolved(window):
            return window
        case let .automaticCandidates(windows):
            return AutomaticQuotaSelection.select(
                candidates: AutomaticQuotaSelection.candidates(windows: windows, snapshot: snapshot),
                provider: provider,
                now: now,
                dataConfidence: snapshot.dataConfidence)?.window
        case .unhandled:
            break
        }
        switch preference {
        case .monthlyPlan:
            return nil
        case .extraUsage:
            return snapshot.providerCost?.spendLimitWindow
        case .primary, .secondary, .tertiary:
            return ProviderUsagePresentation.window(
                in: snapshot,
                following: presentation.requestedMenuBarLaneOrder(for: metric))
        case .primaryAndSecondary:
            // Claude accounts that only expose an enterprise/extra-usage spend limit have no real
            // session/weekly lanes; surface the spend limit (as `.automatic` does) instead of an empty
            // or 0% placeholder lane.
            return ProviderUsagePresentation.mostConstrained(snapshot.primary, snapshot.secondary)
        case .average:
            return Self.averageWindow(snapshot: snapshot, supportsAverage: supportsAverage)
        case .automatic:
            return AutomaticQuotaSelection.select(
                candidates: AutomaticQuotaSelection.candidates(snapshot: snapshot),
                provider: provider,
                now: now,
                dataConfidence: snapshot.dataConfidence)?.window
        }
    }

    static func automaticSelectionPrioritizesExhaustedWindow(for provider: UsageProvider) -> Bool {
        ProviderDescriptorRegistry.descriptor(for: provider).presentation
            .automaticSelectionPrioritizesExhaustedWindow
    }

    private static func averageWindow(
        snapshot: UsageSnapshot,
        supportsAverage: Bool)
        -> RateWindow?
    {
        guard supportsAverage,
              let primary = snapshot.primary,
              let secondary = snapshot.secondary
        else {
            return snapshot.primary ?? snapshot.secondary ?? snapshot.tertiary
        }

        let usedPercent = (primary.usedPercent + secondary.usedPercent) / 2
        return RateWindow(usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
    }

    /// The Claude spend-limit window when the account only exposes an enterprise/extra-usage spend limit
    /// and has no real session/weekly quota lanes (`primary` nil or an explicitly marked placeholder). Lets the
    /// automatic and combined metrics surface the spend limit instead of an empty
    /// or 0% placeholder lane. Returns nil for accounts that expose genuine quota lanes.
    static func claudeSpendLimitWindow(snapshot: UsageSnapshot) -> RateWindow? {
        guard snapshot.primary == nil || snapshot.primary?.isSyntheticPlaceholder == true,
              snapshot.secondary == nil, snapshot.tertiary == nil,
              snapshot.claudeScopedWeeklyWindow == nil
        else { return nil }
        return snapshot.claudeMonthlySpendWindow?.window
    }
}
