import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct InlineCostHistoryDashboardLabelTests {
    private static func antigravitySnapshot(
        now: Date,
        historyDays: Int = 30,
        scanIsPartial: Bool = false) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: 1000,
            sessionCostUSD: 10,
            last30DaysTokens: 1400,
            last30DaysCostUSD: 14,
            historyDays: historyDays,
            historyScanIsPartial: scanIsPartial,
            costProvenance: .listPriceEstimate,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-08",
                    inputTokens: 300,
                    outputTokens: 100,
                    totalTokens: 400,
                    costUSD: 4,
                    modelsUsed: ["gemini-3.8-flash"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gemini-3.8-flash",
                            costUSD: 4,
                            totalTokens: 400),
                    ]),
                CostUsageDailyReport.Entry(
                    date: "2026-07-13",
                    inputTokens: 800,
                    outputTokens: 200,
                    totalTokens: 1000,
                    costUSD: 10,
                    modelsUsed: ["gemini-3.8-flash"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gemini-3.8-flash",
                            costUSD: 10,
                            totalTokens: 1000),
                    ]),
            ],
            updatedAt: now)
    }

    @Test
    func `local cost history Today KPI uses current day session value`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 0,
            sessionCostUSD: 0,
            last30DaysTokens: 275,
            last30DaysCostUSD: 0.25,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 200,
                    outputTokens: 75,
                    totalTokens: 275,
                    costUSD: 0.25,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.kpis.first?.title == "Today")
        #expect(model.inlineUsageDashboard?.kpis.first?.value == "$0.00")
        #expect(model.inlineUsageDashboard?.points.first { $0.id == "2023-11-15" }?.accessibilityValue ==
            "Nov 15, 2023: $0.25 · 275 tokens")
        let hoverDetail = try #require(model.inlineUsageDashboard?.points.first { $0.id == "2023-11-15" }?.hoverDetail)
        #expect(hoverDetail == .init(
            dateLabel: "Nov 15, 2023",
            cost: 0.25,
            tokenCount: 275,
            currencyCode: "USD"))
        let summary = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            hoverDetail.summary
        }
        #expect(summary == "Nov 15, 2023: $0.25 · 275 tokens")
    }

    @Test
    func `local cost history converts from snapshot currency into preferred currency`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 10,
            last30DaysTokens: 100,
            last30DaysCostUSD: 10,
            currencyCode: "EUR",
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 75,
                    outputTokens: 25,
                    totalTokens: 100,
                    costUSD: 10,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            preferredCurrencyCode: "USD",
            now: now))

        let expected = UsageFormatter.convertedCostString(
            10,
            preferredCurrency: "USD",
            providerCurrency: "EUR")
        let expectedValue = UsageFormatter.convertedCost(
            10,
            preferredCurrency: "USD",
            providerCurrency: "EUR").value
        #expect(model.inlineUsageDashboard?.currencyCode == "USD")
        #expect(model.inlineUsageDashboard?.kpis.first?.value == expected)
        #expect(model.inlineUsageDashboard?.points.first { $0.id == "2023-11-15" }?.value == expectedValue)
        #expect(model.inlineUsageDashboard?.points.first { $0.id == "2023-11-15" }?.accessibilityValue ==
            "Nov 15, 2023: \(expected) · 100 tokens")
        #expect(model.inlineUsageDashboard?.points.first { $0.id == "2023-11-15" }?.hoverDetail == .init(
            dateLabel: "Nov 15, 2023",
            cost: expectedValue,
            tokenCount: 100,
            currencyCode: "USD"))
    }

    @Test
    func `hover summary localizes the full sentence and preserves unknown values`() {
        let detail = InlineUsageDashboardModel.HoverDetail(
            dateLabel: "2023-11-15",
            cost: nil,
            tokenCount: nil,
            currencyCode: "USD")

        let english = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            detail.summary
        }
        let simplifiedChinese = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            detail.summary
        }

        #expect(english == "2023-11-15: — · — tokens")
        #expect(simplifiedChinese == "2023-11-15：— · — token")
    }

    @Test
    func `local cost history KPI titles preserve one day and dynamic windows`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2023-11-14",
                inputTokens: 100,
                outputTokens: 50,
                totalTokens: 150,
                costUSD: 0.12,
                modelsUsed: ["claude-sonnet-4"],
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2023-11-15",
                inputTokens: 200,
                outputTokens: 75,
                totalTokens: 275,
                costUSD: 0.25,
                modelsUsed: ["claude-opus-4"],
                modelBreakdowns: nil),
        ]

        func makeModel(historyDays: Int) -> UsageMenuCardView.Model {
            let tokenSnapshot = CostUsageTokenSnapshot(
                sessionTokens: 275,
                sessionCostUSD: 0.25,
                last30DaysTokens: 425,
                last30DaysCostUSD: 0.37,
                historyDays: historyDays,
                daily: daily,
                updatedAt: now)
            return UsageMenuCardView.Model.make(.init(
                provider: .claude,
                metadata: metadata,
                snapshot: UsageSnapshot(
                    primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: now),
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: tokenSnapshot,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: true,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: now))
        }

        let oneDay = makeModel(historyDays: 1)
        #expect(oneDay.inlineUsageDashboard?.kpis.map(\.title) == [
            "Today", "Today", "Latest tokens", "Today tokens",
        ])

        let sevenDays = makeModel(historyDays: 7)
        #expect(sevenDays.inlineUsageDashboard?.kpis.map(\.title) == [
            "Today", "Last 7 days Cost", "Latest tokens", "Last 7 days tokens",
        ])

        #expect(sevenDays.inlineUsageDashboard?.quotaWindows.isEmpty == true)

        let thirtyDays = makeModel(historyDays: 30)
        #expect(thirtyDays.inlineUsageDashboard?.kpis.map(\.title) == [
            "Today", "30d cost", "Latest tokens", "30d tokens",
        ])
    }

    @Test
    func `custom cost history KPI title keeps token label distinct`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 275,
            sessionCostUSD: 0.25,
            last30DaysTokens: 425,
            last30DaysCostUSD: 0.37,
            historyLabel: "This month",
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 200,
                    outputTokens: 75,
                    totalTokens: 275,
                    costUSD: 0.25,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.kpis.map(\.title) == [
            "Today", "This month", "Latest tokens", "This month tokens",
        ])
    }

    @Test
    func `costHistoryInlineDashboard sets currencyCode from snapshot`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 275,
            sessionCostUSD: 0.25,
            last30DaysTokens: 425,
            last30DaysCostUSD: 0.37,
            currencyCode: "USD",
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 200,
                    outputTokens: 75,
                    totalTokens: 275,
                    costUSD: 0.25,
                    modelsUsed: ["test-model"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "test-model",
                            costUSD: 0.25,
                            totalTokens: 275),
                    ]),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.currencyCode == "USD")
        #expect(dashboard.accessibilityLabel == "Claude: 30d cost")
        #expect(dashboard.kpis.map(\.title) == [
            "Today",
            "30d cost",
            "Latest tokens",
            "30d tokens",
        ])
        #expect(dashboard.detailLines == [
            "Top model: test-model",
            "Estimated from local Claude logs at API rates; token totals include cache read/write tokens "
                + "and may differ from Claude Code /status.",
        ])

        let japaneseAccessibilityLabels = CodexBarLocalizationOverride.$appLanguage.withValue("ja") {
            [7, 30].map { historyDays in
                UsageMenuCardView.Model.make(.init(
                    provider: .claude,
                    metadata: metadata,
                    snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
                    credits: nil,
                    creditsError: nil,
                    dashboardError: nil,
                    tokenSnapshot: CostUsageTokenSnapshot(
                        sessionTokens: 275,
                        sessionCostUSD: 0.25,
                        last30DaysTokens: 425,
                        last30DaysCostUSD: 0.37,
                        historyDays: historyDays,
                        daily: tokenSnapshot.daily,
                        updatedAt: now),
                    tokenError: nil,
                    account: AccountInfo(email: nil, plan: nil),
                    isRefreshing: false,
                    lastError: nil,
                    usageBarsShowUsed: false,
                    resetTimeDisplayStyle: .countdown,
                    tokenCostUsageEnabled: true,
                    showOptionalCreditsAndExtraUsage: true,
                    hidePersonalInfo: false,
                    now: now)).inlineUsageDashboard?.accessibilityLabel
            }
        }
        #expect(japaneseAccessibilityLabels == ["Claude: 過去7日間のコスト", "Claude: 過去30日間のコスト"])
    }
}

extension InlineCostHistoryDashboardLabelTests {
    @Test
    func `claude weekly primary still aligns quota-window cost to the live reset`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 15,
            hour: 12)))
        let resetAt = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 18,
            hour: 15)))
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 1000,
            sessionCostUSD: 10,
            last30DaysTokens: 1400,
            last30DaysCostUSD: 14,
            historyDays: 30,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-08",
                    inputTokens: 300,
                    outputTokens: 100,
                    totalTokens: 400,
                    costUSD: 4,
                    modelsUsed: ["claude-opus-4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "claude-opus-4",
                            costUSD: 4,
                            totalTokens: 400),
                    ]),
                CostUsageDailyReport.Entry(
                    date: "2026-07-13",
                    inputTokens: 800,
                    outputTokens: 200,
                    totalTokens: 1000,
                    costUSD: 10,
                    modelsUsed: ["claude-opus-4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "claude-opus-4",
                            costUSD: 10,
                            totalTokens: 1000),
                    ]),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 50,
                    windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
                    resetsAt: resetAt,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            costUsageBucketCalendar: calendar,
            now: now))

        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.quotaWindows.map(\.title) == ["Current window", "Previous window"])
        #expect(dashboard.quotaWindows.map(\.value) == ["$10.00 · 1K", "$4.00 · 400"])
        let currentRange = try #require(dashboard.quotaWindows.first?.range)
        #expect(currentRange.contains("11"))
        #expect(currentRange.contains("18"))
    }

    @Test
    func `quota window range labels use the reset instant and collapse same-day windows`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let locale = Locale(identifier: "en_US")
        let start = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 11,
            hour: 15)))
        let end = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 18,
            hour: 15)))
        let sameDayEnd = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 11,
            hour: 18)))

        let weekRange = Self.normalizedDateText(UsageMenuCardView.Model.quotaWindowRangeLabel(
            start: start,
            end: end,
            calendar: calendar,
            locale: locale))
        let sameDayRange = Self.normalizedDateText(UsageMenuCardView.Model.quotaWindowRangeLabel(
            start: start,
            end: sameDayEnd,
            calendar: calendar,
            locale: locale))
        #expect(weekRange.contains("Jul 11"))
        #expect(weekRange.contains("Jul 18"))
        #expect(weekRange.contains("3:00") || weekRange.contains("15:00"))
        #expect(sameDayRange.contains("Jul 11"))
        #expect(sameDayRange.contains("6:00") || sameDayRange.contains("18:00"))
        #expect(sameDayRange.contains("Jul 18") == false)
    }

    private static func normalizedDateText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
