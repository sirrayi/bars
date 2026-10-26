import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarSpendLimitTests {
    /// 2027-01-01T00:00:00Z. January has 31 days, so a flat 30 day period and the calendar month disagree.
    private static let monthStart = Date(timeIntervalSince1970: 1_798_761_600)
    private static let monthEnd = monthStart.addingTimeInterval(31 * 24 * 60 * 60)
    /// Halfway through the month: 50% of the period has elapsed.
    private let now = monthStart.addingTimeInterval(15.5 * 24 * 60 * 60)

    private func makeStore(showOptionalCreditsAndExtraUsage: Bool = true) -> UsageStore {
        let settings = testSettingsStore(suiteName: "MenuBarSpendLimitTests", userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.showOptionalCreditsAndExtraUsage = showOptionalCreditsAndExtraUsage
        return UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    private func monthlyBudget(
        used: Double = 460,
        limit: Double = 1000,
        currencyCode: String = "USD",
        balance: Double? = nil,
        resetsAt: Date? = MenuBarSpendLimitTests.monthEnd) -> ProviderCostSnapshot
    {
        ProviderCostSnapshot(
            used: used,
            limit: limit,
            currencyCode: currencyCode,
            period: "Monthly",
            resetsAt: resetsAt,
            balance: balance,
            updatedAt: self.now)
    }

    private func snapshot(_ cost: ProviderCostSnapshot?) -> UsageSnapshot {
        UsageSnapshot(primary: nil, secondary: nil, providerCost: cost, updatedAt: self.now)
    }

    @Test
    func `the show credits and extra usage switch hides the budget`() {
        let store = self.makeStore(showOptionalCreditsAndExtraUsage: false)
        defer { store.stopSharedSpendDashboardPublication() }

        let snapshot = self.snapshot(self.monthlyBudget())

        #expect(store.spendLimit(for: .claude, snapshot: snapshot, now: self.now) == nil)
        #expect(store.menuBarLayoutSpend(provider: .claude, snapshot: snapshot, now: self.now) == .unavailable)
    }

    @Test
    func `a snapshot without a positive budget has no spend limit`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }

        #expect(store.spendLimit(for: .claude, snapshot: nil, now: self.now) == nil)
        #expect(store.spendLimit(for: .claude, snapshot: self.snapshot(nil), now: self.now) == nil)
        #expect(store.spendLimit(
            for: .claude,
            snapshot: self.snapshot(self.monthlyBudget(limit: 0)),
            now: self.now) == nil)
    }

    @Test
    func `money text follows the display currency and the budget symbol prefixes the percent`() throws {
        let sterling = MenuBarSpendLimit(
            window: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            cost: self.monthlyBudget(used: 100, limit: 200, currencyCode: "GBP", resetsAt: nil))

        #expect(sterling.currencySymbol == "£")
        #expect(sterling.amountText(preferredCurrency: "auto") == "£100")
        #expect(sterling.budgetText(preferredCurrency: "auto") == "£100 / £200")

        let usedUSD = try #require(CurrencyExchange.shared.convert(amount: 100, from: "GBP", to: "USD"))
        let limitUSD = try #require(CurrencyExchange.shared.convert(amount: 200, from: "GBP", to: "USD"))
        let expectedUsed = UsageFormatter.compactCurrencyString(usedUSD, currencyCode: "USD")
        let expectedLimit = UsageFormatter.compactCurrencyString(limitUSD, currencyCode: "USD")
        #expect(sterling.amountText(preferredCurrency: "USD") == expectedUsed)
        #expect(sterling.budgetText(preferredCurrency: "USD") == "\(expectedUsed) / \(expectedLimit)")

        // Predicate thresholds are USD, and a currency with no exchange rate yields no datum.
        #expect(sterling.usedUSD == usedUSD)
        let unrated = MenuBarSpendLimit(window: sterling.window, cost: self.monthlyBudget(currencyCode: "XXX"))
        #expect(unrated.usedUSD == nil)
        #expect(unrated.remainingUSD == nil)
    }

    @Test
    func `layout spend resolves window text and calendar month pace together`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let snapshot = self.snapshot(self.monthlyBudget())

        let spend = store.menuBarLayoutSpend(provider: .claude, snapshot: snapshot, now: self.now)

        #expect(spend.window?.usedPercent == 46)
        #expect(spend.amount == "$460")
        #expect(spend.budget == "$460 / $1,000")
        #expect(spend.currencySymbol == "$")
        // Half of the 31 day month has elapsed against 46% spent. A flat 30 day period would read -2%.
        #expect(spend.paceDelta == -4)
        #expect(spend.pace == "-4%")

        store.settings.menuBarPaceReservePositive = true
        let flipped = store.menuBarLayoutSpend(provider: .claude, snapshot: snapshot, now: self.now)
        #expect(flipped.pace == "+4%")
        #expect(flipped.paceDelta == -4)
    }

    @Test
    func `a Claude prepaid balance never becomes a spend budget or amount`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let balanceOnly = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: "USD",
            period: "Prepaid",
            balance: 25,
            updatedAt: self.now)

        #expect(store.spendLimit(for: .claude, snapshot: self.snapshot(balanceOnly), now: self.now) == nil)
        #expect(store.menuBarLayoutSpend(
            provider: .claude,
            snapshot: self.snapshot(balanceOnly),
            now: self.now) == .unavailable)

        let spend = store.menuBarLayoutSpend(
            provider: .claude,
            snapshot: self.snapshot(self.monthlyBudget(balance: 25)),
            now: self.now)
        #expect(spend.amount == "$460")
        #expect(spend.budget == "$460 / $1,000")
        #expect(spend.remainingUSD == 540)
    }

    @Test
    func `spend pace appears after one percent of the period even while expected use stays under three`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let month = Self.monthEnd.timeIntervalSince(Self.monthStart)
        let snapshot = self.snapshot(self.monthlyBudget(used: 0))
        let pace = { (elapsed: TimeInterval) in
            store.menuBarLayoutSpend(
                provider: .claude,
                snapshot: snapshot,
                now: Self.monthStart.addingTimeInterval(elapsed)).pace
        }

        #expect(pace(month * 0.005) == nil)
        #expect(pace(month * 0.011) != nil)
    }
}
