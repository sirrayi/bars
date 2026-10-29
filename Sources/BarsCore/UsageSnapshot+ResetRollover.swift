import Foundation

extension RateWindow {
    /// The window as it stands at `now`. Once its reset time has passed, the reported usage belongs to the window
    /// that ended, so the window reads as unused, with no known reset, until the provider reports the new one.
    public func rolledOver(at now: Date) -> RateWindow {
        // Rolling-recovery windows restore only part of their usage at each reset tick.
        guard let resetsAt = self.resetsAt, resetsAt <= now, self.nextRegenPercent == nil else { return self }
        return RateWindow(
            usedPercent: 0,
            windowMinutes: self.windowMinutes,
            resetsAt: nil,
            resetDescription: nil,
            quotaLimit: self.quotaLimit,
            quotaUnit: self.quotaUnit,
            isSyntheticPlaceholder: self.isSyntheticPlaceholder,
            title: self.title)
    }
}

extension UsageSnapshot {
    /// The snapshot as it stands at `now`, with every window whose reset time has passed rolled over.
    public func rollingOverResetWindows(at now: Date) -> UsageSnapshot {
        guard let earliestReset = self.earliestRolloverReset, earliestReset <= now else { return self }
        return self.replacing(
            primary: .value(self.primary?.rolledOver(at: now)),
            secondary: .value(self.secondary?.rolledOver(at: now)),
            tertiary: .value(self.tertiary?.rolledOver(at: now)),
            extraRateWindows: .value(self.extraRateWindows?.map { named in
                NamedRateWindow(
                    id: named.id,
                    title: named.title,
                    window: named.window.rolledOver(at: now),
                    usageKnown: named.usageKnown)
            }))
    }

    /// The earliest reset time, past or future, among the windows that `rollingOverResetWindows(at:)` rolls over.
    public var earliestRolloverReset: Date? {
        self.rateWindows.filter { $0.nextRegenPercent == nil }.compactMap(\.resetsAt).min()
    }

    private var rateWindows: [RateWindow] {
        [self.primary, self.secondary, self.tertiary].compactMap(\.self) +
            (self.extraRateWindows?.map(\.window) ?? [])
    }
}
