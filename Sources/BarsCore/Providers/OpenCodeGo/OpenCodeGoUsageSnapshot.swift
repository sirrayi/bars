import Foundation

public struct OpenCodeGoUsageSnapshot: Sendable {
    public let isBalanceOnly: Bool
    public let hasWeeklyUsage: Bool
    public let hasMonthlyUsage: Bool
    public let rollingUsagePercent: Double
    public let weeklyUsagePercent: Double
    public let monthlyUsagePercent: Double
    public let rollingResetInSec: Int?
    public let weeklyResetInSec: Int?
    public let monthlyResetInSec: Int?
    public private(set) var zenBalanceUSD: Double?
    public let renewsAt: Date?
    public private(set) var daily: [CostUsageDailyReport.Entry]
    /// Console-metered spend and billed token counts. Present only when the workspace API key can
    /// read the Console; the local SQLite history stays the fallback for device-only accounts.
    public private(set) var billed: OpenCodeGoBilledUsage?
    public let updatedAt: Date

    public init(
        isBalanceOnly: Bool = false,
        hasWeeklyUsage: Bool = true,
        hasMonthlyUsage: Bool,
        rollingUsagePercent: Double,
        weeklyUsagePercent: Double,
        monthlyUsagePercent: Double,
        rollingResetInSec: Int?,
        weeklyResetInSec: Int?,
        monthlyResetInSec: Int?,
        zenBalanceUSD: Double? = nil,
        renewsAt: Date? = nil,
        daily: [CostUsageDailyReport.Entry] = [],
        billed: OpenCodeGoBilledUsage? = nil,
        updatedAt: Date)
    {
        self.isBalanceOnly = isBalanceOnly
        self.hasWeeklyUsage = hasWeeklyUsage
        self.hasMonthlyUsage = hasMonthlyUsage
        self.rollingUsagePercent = rollingUsagePercent
        self.weeklyUsagePercent = weeklyUsagePercent
        self.monthlyUsagePercent = monthlyUsagePercent
        self.rollingResetInSec = rollingResetInSec
        self.weeklyResetInSec = weeklyResetInSec
        self.monthlyResetInSec = monthlyResetInSec
        self.zenBalanceUSD = zenBalanceUSD
        self.renewsAt = renewsAt
        self.daily = daily
        self.billed = billed
        self.updatedAt = updatedAt
    }

    public static func zenBalanceOnly(balanceUSD: Double, updatedAt: Date) -> OpenCodeGoUsageSnapshot {
        OpenCodeGoUsageSnapshot(
            isBalanceOnly: true,
            hasWeeklyUsage: false,
            hasMonthlyUsage: false,
            rollingUsagePercent: 0,
            weeklyUsagePercent: 0,
            monthlyUsagePercent: 0,
            rollingResetInSec: 0,
            weeklyResetInSec: 0,
            monthlyResetInSec: 0,
            zenBalanceUSD: balanceUSD,
            updatedAt: updatedAt)
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        if self.isBalanceOnly {
            return UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: self.providerCostSnapshot,
                opencodegoUsage: self,
                updatedAt: self.updatedAt,
                identity: nil)
        }

        let rollingReset = self.rollingResetInSec.map { self.updatedAt.addingTimeInterval(TimeInterval($0)) }
        let primary = RateWindow(
            usedPercent: self.rollingUsagePercent,
            windowMinutes: 5 * 60,
            resetsAt: rollingReset,
            resetDescription: nil)
        let secondary: RateWindow?
        if self.hasWeeklyUsage {
            let weeklyReset = self.weeklyResetInSec.map { self.updatedAt.addingTimeInterval(TimeInterval($0)) }
            secondary = RateWindow(
                usedPercent: self.weeklyUsagePercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: weeklyReset,
                resetDescription: nil)
        } else {
            secondary = nil
        }
        let tertiary: RateWindow?
        if self.hasMonthlyUsage {
            let monthlyReset = self.monthlyResetInSec.map { self.updatedAt.addingTimeInterval(TimeInterval($0)) }
            tertiary = RateWindow(
                usedPercent: self.monthlyUsagePercent,
                windowMinutes: 30 * 24 * 60,
                resetsAt: monthlyReset,
                resetDescription: nil)
        } else {
            tertiary = nil
        }

        var extraWindows: [NamedRateWindow]?
        if let renewsAt = self.renewsAt {
            let renewalWindow = RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: renewsAt,
                resetDescription: nil)
            extraWindows = [NamedRateWindow(id: "renewal", title: "Renews", window: renewalWindow)]
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extraWindows,
            providerCost: self.providerCostSnapshot,
            opencodegoUsage: self,
            updatedAt: self.updatedAt,
            identity: nil)
    }

    private var providerCostSnapshot: ProviderCostSnapshot? {
        self.zenBalanceUSD.map {
            ProviderCostSnapshot(
                used: $0,
                limit: 0,
                currencyCode: "USD",
                period: "Zen balance",
                updatedAt: self.updatedAt)
        }
    }

    public func withZenBalanceUSD(_ balance: Double?) -> OpenCodeGoUsageSnapshot {
        var copy = self
        copy.zenBalanceUSD = balance
        return copy
    }

    /// Replaces the locally estimated usage windows with the server-reported (authoritative)
    /// ones while keeping local-only data such as the daily cost history. The local monthly
    /// window is anchored at the earliest local row, which can drift far from the real billing
    /// cycle (wrong percentage and reset countdown), so whenever web usage is available its
    /// percentages and reset countdowns win. A balance-only web response carries no windows
    /// and must not clobber the local estimate.
    public func applyingWebUsage(_ web: OpenCodeGoUsageSnapshot) -> OpenCodeGoUsageSnapshot {
        guard !web.isBalanceOnly else {
            return self.withZenBalanceUSD(web.zenBalanceUSD ?? self.zenBalanceUSD)
        }
        return OpenCodeGoUsageSnapshot(
            hasWeeklyUsage: web.hasWeeklyUsage,
            hasMonthlyUsage: web.hasMonthlyUsage,
            rollingUsagePercent: web.rollingUsagePercent,
            weeklyUsagePercent: web.weeklyUsagePercent,
            monthlyUsagePercent: web.monthlyUsagePercent,
            rollingResetInSec: web.rollingResetInSec,
            weeklyResetInSec: web.weeklyResetInSec,
            monthlyResetInSec: web.monthlyResetInSec,
            zenBalanceUSD: web.zenBalanceUSD ?? self.zenBalanceUSD,
            renewsAt: web.renewsAt ?? self.renewsAt,
            daily: self.daily,
            billed: self.billed ?? web.billed,
            updatedAt: self.updatedAt)
    }

    /// Applies Console-reported meters, which are exact micro-cent fractions, over a local estimate.
    /// Unlike a browser-session overlay this also adopts the server's billed spend and token history,
    /// because the local SQLite ledger only covers usage this device recorded.
    public func applyingMeteredUsage(_ metered: OpenCodeGoUsageSnapshot) -> OpenCodeGoUsageSnapshot {
        guard !metered.isBalanceOnly else {
            return self.withZenBalanceUSD(metered.zenBalanceUSD ?? self.zenBalanceUSD)
        }
        let billed = metered.billed ?? self.billed
        return OpenCodeGoUsageSnapshot(
            hasWeeklyUsage: metered.hasWeeklyUsage,
            hasMonthlyUsage: metered.hasMonthlyUsage,
            rollingUsagePercent: metered.rollingUsagePercent,
            weeklyUsagePercent: metered.weeklyUsagePercent,
            monthlyUsagePercent: metered.monthlyUsagePercent,
            rollingResetInSec: metered.rollingResetInSec,
            weeklyResetInSec: metered.weeklyResetInSec,
            monthlyResetInSec: metered.monthlyResetInSec,
            zenBalanceUSD: metered.zenBalanceUSD ?? self.zenBalanceUSD,
            renewsAt: metered.renewsAt ?? self.renewsAt,
            daily: metered.daily.isEmpty ? self.daily : metered.daily,
            billed: billed,
            updatedAt: self.updatedAt)
    }

    public func withBilled(_ billed: OpenCodeGoBilledUsage?) -> OpenCodeGoUsageSnapshot {
        guard let billed else { return self }
        var copy = self
        copy.billed = billed
        copy.daily = billed.daily.isEmpty ? self.daily : billed.daily
        return copy
    }

    /// Projects the recorded per-day cost buckets into the shared cost-history model so OpenCode Go
    /// can reuse the same daily usage chart as Claude instead of a bespoke view. Console-metered rows
    /// are the amounts OpenCode charged; local rows are emulated model costs, so they stay estimates.
    public func toCostUsageTokenSnapshot(
        historyDays: Int = 30,
        calendar: Calendar = .current) -> CostUsageTokenSnapshot
    {
        CostUsageFetcher.tokenSnapshot(
            from: CostUsageDailyReport(data: self.daily, summary: nil),
            now: self.updatedAt,
            historyDays: historyDays,
            calendar: calendar,
            meteredCostUSD: self.billed?.costUSD,
            costProvenance: self.billed == nil ? .listPriceEstimate : .vendorMetered)
    }
}
