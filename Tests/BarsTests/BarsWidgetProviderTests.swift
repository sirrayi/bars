import Foundation
import Testing
@testable import BarsCore
@testable import BarsWidget

struct BarsWidgetProviderTests {
    @Test
    func `widget token counts use compact shared formatting`() {
        #expect(WidgetFormat.tokenCount(999) == "999 tokens")
        #expect(WidgetFormat.tokenCount(9_400_000) == "9.4M tokens")
        #expect(WidgetFormat.tokenCount(94_500_000) == "94M tokens")
        #expect(WidgetFormat.tokenCount(10_600_000_000) == "11B tokens")
    }

    @Test
    func `usage display follows remaining and used preference`() {
        #expect(WidgetUsageDisplay.percent(fromRemaining: 48, showUsed: false) == 48)
        #expect(WidgetUsageDisplay.percent(fromRemaining: 48, showUsed: true) == 52)
        #expect(WidgetUsageDisplay.percent(fromRemaining: nil, showUsed: true) == nil)
    }

    @Test
    func `small widget falls back to local cost when quota rows are unavailable`() {
        let tokenUsage = WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: 1.25,
            sessionTokens: 4200,
            last30DaysCostUSD: 12.50,
            last30DaysTokens: 42000,
            currencyCode: "USD",
            sessionLabel: "Today",
            last30DaysLabel: "30d")
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: tokenUsage,
            dailyUsage: [])
        let windowedEntry = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: Date(),
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            usageRows: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: tokenUsage,
            dailyUsage: [])

        #expect(WidgetUsageRow.compactTokenUsage(for: entry)?.sessionTokens == 4200)
        #expect(WidgetUsageRow.compactTokenUsage(for: windowedEntry) == nil)
    }

    @Test
    func `provider choice supports opencode go`() {
        #expect(ProviderChoice(provider: .opencodego) == .opencodego)
        #expect(ProviderChoice.opencodego.provider == .opencodego)
    }

    @Test
    func `provider choice supports devin`() {
        #expect(ProviderChoice(provider: .devin) == .devin)
        #expect(ProviderChoice.devin.provider == .devin)
    }

    @Test
    func `widget entry carries devin overage balance through providerCost`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .devin,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            providerCost: ProviderCostSnapshot(
                used: 48.0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let encoded = try? JSONEncoder().encode(entry)
        #expect(encoded != nil)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(WidgetSnapshot.ProviderEntry.self, from: $0) }
        #expect(decoded?.providerCost?.period == "Extra usage balance")
        #expect(decoded?.providerCost?.used == 48.0)
        #expect(decoded?.providerCost?.limit == 0)
        #expect(decoded?.provider == .devin)
    }

    @Test
    func `widget balance formatter renders devin extra usage balance`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .devin,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            providerCost: ProviderCostSnapshot(
                used: 48.0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let line = WidgetBalanceFormatter.extraUsageBalance(for: entry)
        #expect(line?.title == "Extra usage")
        #expect(line?.value.hasPrefix("Balance: ") == true)
        #expect(line?.value.contains("48") == true)
    }

    @Test
    func `compact credits render Devin extra usage balance`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .devin,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            providerCost: ProviderCostSnapshot(
                used: 48.0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))

        let display = CompactMetricFormatter.display(for: entry, metric: .credits)

        #expect(display.value.contains("48"))
        #expect(display.label == "Extra usage balance")
        #expect(display.detail == nil)
    }

    @Test
    func `supported providers fall back to claude when snapshot is empty`() {
        let snapshot = WidgetSnapshot(entries: [], enabledProviders: [], generatedAt: Date())

        #expect(BarsSwitcherTimelineProvider.supportedProviders(from: snapshot) == [.claude])
    }

    @Test
    func `codex weekly only widget rows omit session`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .opencode,
            updatedAt: now,
            primary: nil,
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry)

        #expect(rows.count == 1)
        #expect(rows.first?.title == "Weekly")
        #expect(rows.first?.percentLeft == 75)
    }

    @Test
    func `widget usage rows prefer projected rows over legacy slots`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .opencode,
            updatedAt: now,
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "weekly", title: "Weekly", percentLeft: 75),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry)

        #expect(rows == [WidgetUsageRow(id: "weekly", title: "Weekly", percentLeft: 75)])
    }

    @Test
    func `widget configuration intents default to claude and credits`() {
        let providerIntent = ProviderSelectionIntent()
        let compactIntent = CompactMetricSelectionIntent()
        let burnIntent = BurnDownSelectionIntent()
        let combinedBurnIntent = BurnProviderSelectionIntent()

        #expect(providerIntent.provider == .claude)
        #expect(compactIntent.provider == .claude)
        #expect(compactIntent.metric == .credits)
        #expect(burnIntent.provider == .claude)
        #expect(burnIntent.window == .session)
        #expect(combinedBurnIntent.provider == .claude)
    }

    @Test
    func `burn down uses an exact provider entry`() {
        let snapshot = Self.burnSnapshot(provider: .claude, primaryUsed: 20, secondaryUsed: 30)

        #expect(BurnDownState(snapshot: snapshot, provider: .opencode, selection: .session) == nil)
        #expect(BurnDownState(snapshot: snapshot, provider: .claude, selection: .session) != nil)
    }

    @Test
    func `burn down preview includes session and weekly windows`() throws {
        let snapshot = WidgetPreviewData.snapshot()

        let session = try #require(BurnDownState(snapshot: snapshot, provider: .claude, selection: .session))
        let weekly = try #require(BurnDownState(snapshot: snapshot, provider: .claude, selection: .weekly))

        #expect(session.selectedWindow?.windowMinutes == 300)
        #expect(weekly.selectedWindow?.windowMinutes == 10080)
    }

    @Test
    func `burn down selection does not fall back to another window`() throws {
        let weeklyOnly = Self.burnSnapshot(provider: .opencode, primaryUsed: nil, secondaryUsed: 30)
        let sessionOnly = Self.burnSnapshot(provider: .opencode, primaryUsed: 20, secondaryUsed: nil)
        let weeklyStoredInPrimary = Self.burnSnapshot(
            provider: .claude,
            primaryUsed: 30,
            secondaryUsed: nil,
            primaryWindowMinutes: 7 * 24 * 60)

        let weeklyOnlySession = try #require(BurnDownState(
            snapshot: weeklyOnly,
            provider: .opencode,
            selection: .session))
        let weeklyOnlyWeekly = try #require(BurnDownState(
            snapshot: weeklyOnly,
            provider: .opencode,
            selection: .weekly))
        let sessionOnlySession = try #require(BurnDownState(
            snapshot: sessionOnly,
            provider: .opencode,
            selection: .session))
        let sessionOnlyWeekly = try #require(BurnDownState(
            snapshot: sessionOnly,
            provider: .opencode,
            selection: .weekly))
        let weeklyPrimarySession = try #require(BurnDownState(
            snapshot: weeklyStoredInPrimary,
            provider: .claude,
            selection: .session))
        let weeklyPrimaryWeekly = try #require(BurnDownState(
            snapshot: weeklyStoredInPrimary,
            provider: .claude,
            selection: .weekly))

        #expect(weeklyOnlySession.selectedWindow == nil)
        #expect(weeklyOnlyWeekly.selectedWindow == weeklyOnlyWeekly.secondaryWindow)
        #expect(sessionOnlySession.selectedWindow == sessionOnlySession.primaryWindow)
        #expect(sessionOnlyWeekly.selectedWindow == nil)
        #expect(weeklyPrimarySession.selectedWindow == nil)
        #expect(weeklyPrimaryWeekly.selectedWindow?.usedPercent == 30)
    }

    @Test
    func `expired weekly reset no longer blocks the session chart`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = Self.burnSnapshot(
            provider: .opencode,
            primaryUsed: 20,
            secondaryUsed: 100,
            primaryReset: now.addingTimeInterval(300),
            secondaryReset: now.addingTimeInterval(-1))
        let state = try #require(BurnDownState(
            snapshot: snapshot,
            provider: .opencode,
            selection: .session,
            now: now))

        #expect(!state.secondaryExhausted)
        #expect(state.primaryWindow?.remainingPercent == 80)
        #expect(!state.blankPrimaryChart)
        #expect(state.selectedResetOverride == nil)
    }

    @Test
    func `explicit reset takes precedence over estimated reset`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = now.addingTimeInterval(600)

        #expect(burnEffectiveResetDate(
            explicitResetAt: now.addingTimeInterval(-1),
            estimatedResetMinutes: 5,
            now: now) == nil)
        #expect(burnEffectiveResetDate(
            explicitResetAt: future,
            estimatedResetMinutes: 5,
            now: now) == future)
        #expect(burnEffectiveResetDate(
            explicitResetAt: nil,
            estimatedResetMinutes: 5,
            now: now) == now.addingTimeInterval(300))
        #expect(burnEffectiveResetDate(
            explicitResetAt: nil,
            estimatedResetMinutes: nil,
            now: now) == nil)
    }

    @Test
    func `burn down axis shares the effective estimated reset`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let effectiveReset = try #require(burnEffectiveResetDate(
            explicitResetAt: nil,
            estimatedResetMinutes: 90,
            now: now))

        let axis = burnAxisDateRange(
            effectiveResetAt: effectiveReset,
            windowMinutes: 300,
            now: now)

        #expect(axis.reset == effectiveReset)
        #expect(axis.start == effectiveReset.addingTimeInterval(-5 * 60 * 60))
    }

    @Test
    func `burn down refreshes immediately after the earliest future reset`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = Self.burnSnapshot(
            provider: .opencode,
            primaryUsed: 20,
            secondaryUsed: 30,
            primaryReset: now.addingTimeInterval(360),
            secondaryReset: now.addingTimeInterval(420))

        #expect(BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: .opencode, now: now)
            == now.addingTimeInterval(361))
    }

    @Test
    func `burn down refresh clamps to minimum interval`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = Self.burnSnapshot(
            provider: .opencode,
            primaryUsed: 20,
            secondaryUsed: 30,
            primaryReset: now.addingTimeInterval(60),
            secondaryReset: now.addingTimeInterval(120))

        #expect(BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: .opencode, now: now)
            == now.addingTimeInterval(300))
    }

    @Test
    func `burn down refresh ignores past resets and unrelated provider entries`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = Self.burnSnapshot(
            provider: .claude,
            primaryUsed: 20,
            secondaryUsed: 30,
            primaryReset: now.addingTimeInterval(-60),
            secondaryReset: now.addingTimeInterval(-30))
        let fallback = now.addingTimeInterval(30 * 60)

        #expect(BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: .claude, now: now) == fallback)
        #expect(BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: .opencode, now: now) == fallback)
    }

    private static func burnSnapshot(
        provider: UsageProvider,
        primaryUsed: Double?,
        secondaryUsed: Double?,
        primaryReset: Date? = Date(timeIntervalSince1970: 1_800_000_000),
        secondaryReset: Date? = Date(timeIntervalSince1970: 1_800_000_000),
        primaryWindowMinutes: Int = 5 * 60,
        secondaryWindowMinutes: Int = 7 * 24 * 60) -> WidgetSnapshot
    {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: primaryUsed.map {
                RateWindow(
                    usedPercent: $0,
                    windowMinutes: primaryWindowMinutes,
                    resetsAt: primaryReset,
                    resetDescription: nil)
            },
            secondary: secondaryUsed.map {
                RateWindow(
                    usedPercent: $0,
                    windowMinutes: secondaryWindowMinutes,
                    resetsAt: secondaryReset,
                    resetDescription: nil)
            },
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        return WidgetSnapshot(entries: [entry], generatedAt: entry.updatedAt)
    }
}

extension BarsWidgetProviderTests {
    @Test
    func `usage history chart mode requires every point to expose cost`() {
        let costPoints = [
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-01", totalTokens: 100, costUSD: 1.2),
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-02", totalTokens: 200, costUSD: 2.4),
        ]
        let tokenPoints = [
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-01", totalTokens: 100, costUSD: nil),
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-02", totalTokens: 200, costUSD: nil),
        ]
        let mixedPoints = [
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-01", totalTokens: 100, costUSD: 1.2),
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-02", totalTokens: 200, costUSD: nil),
        ]
        let emptyPoints: [WidgetSnapshot.DailyUsagePoint] = []

        #expect(UsageHistoryChartMode.isCostMode(costPoints) == true)
        #expect(UsageHistoryChartMode.isCostMode(tokenPoints) == false)
        #expect(UsageHistoryChartMode.isCostMode(mixedPoints) == false)
        #expect(UsageHistoryChartMode.isCostMode(emptyPoints) == false)
    }
}
