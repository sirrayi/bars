import BarsCore
import Foundation

/// A provider-reported spend budget behind the menu bar layout's Spend window.
struct MenuBarSpendLimit {
    let window: RateWindow
    let cost: ProviderCostSnapshot

    /// The budget currency's own symbol, which prefixes the Spend percent whatever currency the amounts display in.
    var currencySymbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = self.cost.currencyCode
        formatter.locale = Locale(identifier: "en_US")
        return formatter.currencySymbol.flatMap { $0.isEmpty ? nil : $0 } ?? "$"
    }

    func amountText(preferredCurrency: String) -> String? {
        self.displayText(self.cost.used, preferredCurrency: preferredCurrency)
    }

    func budgetText(preferredCurrency: String) -> String? {
        let used = self.displayText(self.cost.used, preferredCurrency: preferredCurrency)
        return "\(used) / \(self.displayText(self.cost.limit, preferredCurrency: preferredCurrency))"
    }

    /// Thresholds are USD. `convertedCost` hands back the source amount unchanged when no rate exists, so
    /// the datum is kept only when the conversion actually landed in USD.
    var usedUSD: Double? {
        self.usdAmount(self.cost.used)
    }

    var remainingUSD: Double? {
        self.usdAmount(max(0, self.cost.limit - self.cost.used))
    }

    private func usdAmount(_ value: Double) -> Double? {
        let converted = UsageFormatter.convertedCost(
            value,
            preferredCurrency: "USD",
            providerCurrency: self.cost.currencyCode)
        return converted.currencyCode == "USD" ? converted.value : nil
    }

    private func displayText(_ value: Double, preferredCurrency: String) -> String {
        let converted = UsageFormatter.convertedCost(
            value,
            preferredCurrency: preferredCurrency,
            providerCurrency: self.cost.currencyCode)
        return UsageFormatter.compactCurrencyString(converted.value, currencyCode: converted.currencyCode)
    }
}

/// Menu-bar-ready Spend values resolved in one pass.
struct MenuBarLayoutSpend: Equatable {
    var window: RateWindow?
    var pace: String?
    var paceDelta: Double?
    var amount: String?
    var budget: String?
    var currencySymbol: String
    var usedUSD: Double?
    var remainingUSD: Double?

    static let unavailable = MenuBarLayoutSpend(
        window: nil,
        pace: nil,
        paceDelta: nil,
        amount: nil,
        budget: nil,
        currencySymbol: "$",
        usedUSD: nil,
        remainingUSD: nil)
}

extension UsageStore {
    /// Amounts come from the reported cost; the window comes from the `.extraUsage` menu bar metric, so a
    /// provider that projects its own window for that metric (Claude's calendar month) governs Spend too.
    func spendLimit(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        now: Date = .init())
        -> MenuBarSpendLimit?
    {
        guard self.settings.showOptionalCreditsAndExtraUsage,
              ProviderDescriptorRegistry.descriptor(for: provider).menuBarMetrics.supports(.extraUsage)
        else { return nil }
        guard let cost = snapshot?.providerCost, cost.used >= 0 else { return nil }
        let costSnapshot = snapshot?.with(providerCost: cost)
            ?? UsageSnapshot(primary: nil, secondary: nil, providerCost: cost, updatedAt: cost.updatedAt)
        guard let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .extraUsage,
            provider: provider,
            snapshot: costSnapshot,
            supportsAverage: false,
            now: now)
        else { return nil }
        return MenuBarSpendLimit(window: window, cost: cost)
    }

    func menuBarLayoutSpend(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        now: Date = .init())
        -> MenuBarLayoutSpend
    {
        guard let limit = self.spendLimit(for: provider, snapshot: snapshot, now: now) else { return .unavailable }
        let preferredCurrency = self.settings.preferredCurrencyCode
        // `weeklyPace` would score a window with no duration against a fabricated week (Codex branch).
        let paceWindow = limit.window.windowMinutes == nil ? nil : limit.window
        let dataConfidence = snapshot?.dataConfidence ?? .unknown
        return MenuBarLayoutSpend(
            window: limit.window,
            pace: self.menuBarLayoutPaceText(
                provider: provider,
                window: paceWindow,
                dataConfidence: dataConfidence,
                now: now,
                minimumElapsedPercent: 1),
            paceDelta: self.menuBarLayoutPaceDelta(
                provider: provider,
                window: paceWindow,
                dataConfidence: dataConfidence,
                now: now,
                minimumElapsedPercent: 1),
            amount: limit.amountText(preferredCurrency: preferredCurrency),
            budget: limit.budgetText(preferredCurrency: preferredCurrency),
            currencySymbol: limit.currencySymbol,
            usedUSD: limit.usedUSD,
            remainingUSD: limit.remainingUSD)
    }
}
