import BarsCore
import Foundation

@MainActor
extension UsageStore {
    func weeklyPace(
        provider: UsageProvider,
        window: RateWindow,
        dataConfidence: UsageDataConfidence,
        now: Date = .init(),
        minimumExpectedPercent: Double = 3,
        minimumElapsedPercent: Double? = nil) -> UsagePace?
    {
        guard ProviderDescriptorRegistry.descriptor(for: provider).pace.allowsPace(dataConfidence: dataConfidence),
              window.remainingPercent > 0 else { return nil }
        // Generic providers must carry an explicit window duration. Using the 10080-minute fallback for
        // windows without windowMinutes would fabricate a weekly pace for non-weekly windows.
        guard window.windowMinutes != nil else { return nil }
        // Expand a monthly sentinel to the real calendar cycle before scoring. The menu card and the
        // CLI both resolve first, so skipping it here would score a billing period as a flat 30 days
        // and disagree with them — and a 31-day cycle would exceed the sentinel outright, dropping the
        // pace for the first day of every long month.
        let elapsedWindow = self.paceWindowForElapsedEligibility(provider: provider, window: window)
        let resolved = UsagePace.weekly(
            window: elapsedWindow,
            now: now,
            defaultWindowMinutes: 10080,
            workDays: self.settings.weeklyProgressWorkDays)

        guard let resolved else { return nil }
        let expectedFloorMet = resolved.expectedUsedPercent >= minimumExpectedPercent
        let elapsedFloorMet = minimumElapsedPercent.map { minimum in
            (Self.windowElapsedPercent(window: elapsedWindow, now: now) ?? 0) >= minimum
        } ?? false
        guard expectedFloorMet || elapsedFloorMet else { return nil }
        return resolved
    }

    /// Signed pace delta (`+11%`, `-8%`, `0%`) for a menu-bar layout pace token, or nil when the window
    /// carries no pace-capable metadata. Shared by the status item and the layout editor preview so both
    /// resolve pace through the same historical/work-day settings as the menu card.
    func menuBarLayoutPaceText(
        provider: UsageProvider,
        window: RateWindow?,
        dataConfidence: UsageDataConfidence,
        now: Date = .init(),
        minimumExpectedPercent: Double = 3,
        minimumElapsedPercent: Double? = nil)
        -> String?
    {
        window
            .flatMap {
                self.weeklyPace(
                    provider: provider,
                    window: $0,
                    dataConfidence: dataConfidence,
                    now: now,
                    minimumExpectedPercent: minimumExpectedPercent,
                    minimumElapsedPercent: minimumElapsedPercent)
            }
            .flatMap { MenuBarDisplayText.paceText(pace: $0, reservePositive: self.settings.menuBarPaceReservePositive)
            }
    }

    /// Rounded usage-ahead delta for colors and conditional predicates, independent of the display sign.
    func menuBarLayoutPaceDelta(
        provider: UsageProvider,
        window: RateWindow?,
        dataConfidence: UsageDataConfidence,
        now: Date = .init(),
        minimumExpectedPercent: Double = 3,
        minimumElapsedPercent: Double? = nil)
        -> Double?
    {
        window
            .flatMap {
                self.weeklyPace(
                    provider: provider,
                    window: $0,
                    dataConfidence: dataConfidence,
                    now: now,
                    minimumExpectedPercent: minimumExpectedPercent,
                    minimumElapsedPercent: minimumElapsedPercent)
            }
            .map { $0.deltaPercent.rounded() }
    }

    /// The weekly menu token uses elapsed progress as an eligibility fallback.
    func paceWindowForElapsedEligibility(provider: UsageProvider, window: RateWindow) -> RateWindow {
        guard window.windowMinutes != nil else { return window }
        return ProviderDescriptorRegistry.descriptor(for: provider)
            .pace
            .resolvedResetWindowForPace(window)
    }

    nonisolated static func paceElapsedBoundary(
        window: RateWindow,
        minimumElapsedPercent: Double) -> Date?
    {
        guard minimumElapsedPercent > 0,
              let resetsAt = window.resetsAt,
              let windowMinutes = window.windowMinutes,
              windowMinutes > 0
        else { return nil }
        let duration = TimeInterval(windowMinutes) * 60
        let start = resetsAt.addingTimeInterval(-duration)
        return start.addingTimeInterval(duration * minimumElapsedPercent / 100)
    }

    private static func windowElapsedPercent(window: RateWindow, now: Date) -> Double? {
        guard let resetsAt = window.resetsAt,
              let windowMinutes = window.windowMinutes,
              windowMinutes > 0
        else { return nil }
        let duration = TimeInterval(windowMinutes) * 60
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(start)
        return min(100, max(0, elapsed / duration * 100))
    }
}
