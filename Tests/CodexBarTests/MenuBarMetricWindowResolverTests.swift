import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuBarMetricWindowResolverTests {
    @Test
    func `combined primary and secondary metric uses the most constrained lane`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 91, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .primaryAndSecondary,
            provider: .codex,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 91)
        #expect(window?.windowMinutes == 7 * 24 * 60)
    }

    @Test
    func `automatic metric prioritizes exhausted default secondary window`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: "Primary"),
            secondary: RateWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: nil, resetDescription: "Secondary"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .opencode,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.resetDescription == "Secondary")
        #expect(window?.usedPercent == 100)
    }

    @Test
    func `automatic metric prioritizes exhausted default tertiary window`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: "Primary"),
            secondary: RateWindow(usedPercent: 55, windowMinutes: 10080, resetsAt: nil, resetDescription: "Secondary"),
            tertiary: RateWindow(usedPercent: 100, windowMinutes: 43200, resetsAt: nil, resetDescription: "Tertiary"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .opencode,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.resetDescription == "Tertiary")
        #expect(window?.usedPercent == 100)
    }

    @Test
    func `automatic metric chooses highest usage without a forecast`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: "Primary"),
            secondary: RateWindow(usedPercent: 99, windowMinutes: 10080, resetsAt: nil, resetDescription: "Secondary"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .opencode,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.resetDescription == "Secondary")
        #expect(window?.usedPercent == 99)
    }

    private static func antigravitySummarySnapshot(
        rows: [(idSuffix: String, windowMinutes: Int, usedPercent: Double, usageKnown: Bool)])
        -> UsageSnapshot
    {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: rows.map { row in
                NamedRateWindow(
                    id: "antigravity-quota-summary-\(row.idSuffix)",
                    title: row.idSuffix,
                    window: RateWindow(
                        usedPercent: row.usedPercent,
                        windowMinutes: row.windowMinutes,
                        resetsAt: nil,
                        resetDescription: nil),
                    usageKnown: row.usageKnown)
            },
            updatedAt: Date())
    }

    @Test
    func `automatic metric uses claude enterprise spend limit`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Spend limit",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(abs((window?.usedPercent ?? 0) - 6.703) < 0.0001)
    }

    @Test
    func `automatic metric uses marked claude web spend limit placeholder`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(abs((window?.usedPercent ?? 0) - 6.703) < 0.0001)
    }

    @Test
    func `combined metric keeps real zero claude session when spend limit exists`() {
        let primary = RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .primaryAndSecondary,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window == primary)
    }

    @Test
    func `automatic metric keeps real zero claude session when spend limit exists`() {
        let primary = RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window == primary)
    }

    @Test
    func `automatic metric keeps claude quota window when extra usage is optional`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 42)
    }

    @Test
    func `automatic metric keeps claude zero quota window when reset exists`() {
        let reset = Date(timeIntervalSince1970: 1000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: reset, resetDescription: "later"),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.resetsAt == reset)
    }
}
