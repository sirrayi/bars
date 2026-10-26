import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SessionEquivalentForecastTests {
    private static let weeklyReset = Date(timeIntervalSince1970: 2_000_000_000)

    @Test
    func `uses the median of the latest seven completed active session windows`() throws {
        let fixture = Self.historyFixture(burns: [5, 4, 8, 6, 10, 12, 14, 16])

        let estimate = try #require(SessionEquivalentBurnEstimator.estimate(
            histories: fixture.histories,
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)))

        #expect(estimate.sampleCount == 7)
        #expect(estimate.medianWeeklyPercentPerWindow == 10)
    }

    @Test
    func `normalizes aligned partial session observations to a full allowance`() throws {
        let fixture = Self.alignedPartialHistoryFixture()

        let estimate = try #require(SessionEquivalentBurnEstimator.estimate(
            histories: fixture.histories,
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)))

        #expect(estimate.sampleCount == 3)
        #expect(estimate.medianWeeklyPercentPerWindow == 10)
    }

    @Test
    func `rejects partial sessions whose weekly burn cannot be aligned`() {
        let fixture = Self.historyFixture(samples: [
            (sessionUsedPercent: 20, weeklyBurnPercent: 2),
            (sessionUsedPercent: 40, weeklyBurnPercent: 4),
            (sessionUsedPercent: 60, weeklyBurnPercent: 6),
        ])

        #expect(SessionEquivalentBurnEstimator.estimate(
            histories: fixture.histories,
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)) == nil)
    }

    @Test
    func `uses eligible boundary samples when a closer sample follows the boundary`() throws {
        let fixture = Self.straddledBoundaryHistoryFixture()

        let estimate = try #require(SessionEquivalentBurnEstimator.estimate(
            histories: fixture.histories,
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)))

        #expect(estimate.sampleCount == 3)
        #expect(estimate.medianWeeklyPercentPerWindow == 10)
    }

    @Test
    func `requires three completed windows with measurable burn`() {
        let fixture = Self.historyFixture(burns: [8, 12])

        let estimate = SessionEquivalentBurnEstimator.estimate(
            histories: fixture.histories,
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600))

        #expect(estimate == nil)
    }

    @Test
    func `rejects zero burn and non finite division inputs`() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil)

        #expect(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: weekly,
            burnEstimate: SessionEquivalentBurnEstimate(
                medianWeeklyPercentPerWindow: 0,
                sampleCount: 3),
            now: now,
            workDays: nil) == nil)
        #expect(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: weekly,
            burnEstimate: SessionEquivalentBurnEstimate(
                medianWeeklyPercentPerWindow: .infinity,
                sampleCount: 3),
            now: now,
            workDays: nil) == nil)
    }

    @Test
    func `rejects synthetic Claude session placeholder with a future reset`() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil,
            isSyntheticPlaceholder: true)
        let weekly = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil)

        #expect(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: weekly,
            burnEstimate: SessionEquivalentBurnEstimate(
                medianWeeklyPercentPerWindow: 10,
                sampleCount: 3),
            now: now,
            workDays: nil) == nil)
    }

    @Test
    func `privacy redaction preserves session equivalent detail`() throws {
        let detail = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 4,
            windowsUntilReset: 9,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 60))
        let metric = UsageMenuCardView.Model.Metric(
            id: "weekly",
            title: "Weekly",
            percent: 60,
            percentStyle: .used,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false,
            sessionEquivalentDetail: detail)

        let redacted = UsageMenuCardView.Model.redactedMetrics(
            [metric],
            provider: .claude,
            hidePersonalInfo: true)

        let redactedDetail = try #require(redacted.first?.sessionEquivalentDetail)
        #expect(redactedDetail.leftText == detail.leftText)
        #expect(redactedDetail.rightText == detail.rightText)
    }

    @Test(arguments: [5, 6])
    func `work day setting excludes weekend capacity`(workDays: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 17,
            hour: 12)))
        let reset = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 20,
            hour: 12)))
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 60,
            windowMinutes: 10080,
            resetsAt: reset,
            resetDescription: nil)
        let burn = SessionEquivalentBurnEstimate(medianWeeklyPercentPerWindow: 10, sampleCount: 3)

        let everyDay = try #require(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: weekly,
            burnEstimate: burn,
            now: now,
            workDays: nil,
            calendar: calendar))
        let weekdays = try #require(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: weekly,
            burnEstimate: burn,
            now: now,
            workDays: workDays,
            calendar: calendar))

        #expect(everyDay.windowsUntilReset == 14)
        #expect(weekdays.windowsUntilReset == (workDays == 5 ? 4 : 9))
    }

    @Test
    func `formats session quota estimate and reset windows`() {
        let early = SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 4,
            windowsUntilReset: 9,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 60)
        let stranded = SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 10,
            windowsUntilReset: 9,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 20)

        let earlyText = UsagePaceText.sessionEquivalentDetail(forecast: early)
        let strandedText = UsagePaceText.sessionEquivalentDetail(forecast: stranded)

        #expect(earlyText.leftText == "Est. 4 session quotas left")
        #expect(earlyText.rightText == "9 windows until reset")
        #expect(earlyText.accessibilityLabel == "Est. 4 session quotas left · 9 windows until reset")
        #expect(strandedText.leftText == "Est. 10 session quotas left")
    }

    @Test
    func `formats quota estimates with up to one decimal and pluralizes units`() {
        let equal = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 2,
            windowsUntilReset: 2,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 80))
        let roundedSingular = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 1.04,
            windowsUntilReset: 2,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 90))
        let close = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 8.6,
            windowsUntilReset: 9,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 14))

        #expect(equal.leftText == "Est. 2 session quotas left")
        #expect(roundedSingular.leftText == "Est. 1 session quota left")
        #expect(roundedSingular.rightText == "2 windows until reset")
        #expect(close.leftText == "Est. 8.6 session quotas left")
        #expect(close.rightText == "9 windows until reset")
    }

    @Test
    func `formats sub-one quota and singular reset window`() {
        let detail = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 0.3,
            windowsUntilReset: 1,
            availableWindowsUntilReset: 1.8,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 95))

        #expect(detail.leftText == "Est. 0.3 session quota left")
        #expect(detail.rightText == "1 window until reset")
    }

    @Test
    func `reset tolerance compares actual distance across bucket boundaries`() throws {
        let fixture = Self.historyFixture(burns: [4, 6, 8])
        let session = PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: fixture.histories[0].entries.enumerated().map { index, entry in
                planEntry(
                    at: entry.capturedAt,
                    usedPercent: entry.usedPercent,
                    resetsAt: entry.resetsAt?.addingTimeInterval(index.isMultiple(of: 2) ? 59 : 61))
            })
        let weekly = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: fixture.histories[1].entries.enumerated().map { index, entry in
                planEntry(
                    at: entry.capturedAt,
                    usedPercent: entry.usedPercent,
                    resetsAt: entry.resetsAt?.addingTimeInterval(index.isMultiple(of: 2) ? 59 : 61))
            })

        let estimate = try #require(SessionEquivalentBurnEstimator.estimate(
            histories: [session, weekly],
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)))

        #expect(estimate.sampleCount == 3)
        #expect(estimate.medianWeeklyPercentPerWindow == 6)
    }

    @Test
    func `rejects hostile dates and percentages and normalizes unsorted history`() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        let burn = SessionEquivalentBurnEstimate(medianWeeklyPercentPerWindow: 10, sampleCount: 3)
        let extremeDate = Date(timeIntervalSinceReferenceDate: 1e30)

        #expect(SessionEquivalentForecast.make(
            sessionWindow: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: extremeDate,
                resetDescription: nil),
            weeklyWindow: RateWindow(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(24 * 3600),
                resetDescription: nil),
            burnEstimate: burn,
            now: now,
            workDays: nil) == nil)
        #expect(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: RateWindow(
                usedPercent: -1,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(24 * 3600),
                resetDescription: nil),
            burnEstimate: burn,
            now: now,
            workDays: nil) == nil)

        let fixture = Self.historyFixture(burns: [4, 6, 8])
        let encodedSession = try JSONEncoder().encode(fixture.histories[0])
        var sessionJSON = try #require(JSONSerialization.jsonObject(with: encodedSession) as? [String: Any])
        let entriesJSON = try #require(sessionJSON["entries"] as? [[String: Any]])
        // Decoding sorts entries (PlanUtilizationSeriesHistory.init(from:)), so a reversed payload
        // normalizes to the same series and yields the same estimate as the sorted fixture above.
        sessionJSON["entries"] = Array(entriesJSON.reversed())
        let shuffledData = try JSONSerialization.data(withJSONObject: sessionJSON)
        let shuffledSession = try JSONDecoder().decode(PlanUtilizationSeriesHistory.self, from: shuffledData)
        #expect(shuffledSession == fixture.histories[0])
        let shuffledEstimate = try #require(SessionEquivalentBurnEstimator.estimate(
            histories: [shuffledSession, fixture.histories[1]],
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)))
        #expect(shuffledEstimate.sampleCount == 3)
        #expect(shuffledEstimate.medianWeeklyPercentPerWindow == 6)

        let huge = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: .greatestFiniteMagnitude,
            windowsUntilReset: 2,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 1))
        #expect(huge.leftText == "Est. 1,000,000 session quotas left")
    }

    @Test
    func `does not replace unusable recent windows with older samples`() throws {
        let fixture = Self.historyFixture(burns: [20, 2, 4, 6, 8, 10, 12, 14])
        let lastReset = fixture.currentSessionReset.addingTimeInterval(-5 * 3600)
        let lastStart = lastReset.addingTimeInterval(-5 * 3600)
        let weekly = fixture.histories[1]
        let missingLatestBoundaries = PlanUtilizationSeriesHistory(
            name: weekly.name,
            windowMinutes: weekly.windowMinutes,
            entries: weekly.entries.filter { $0.capturedAt != lastStart && $0.capturedAt != lastReset })

        let estimate = try #require(SessionEquivalentBurnEstimator.estimate(
            histories: [fixture.histories[0], missingLatestBoundaries],
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)))

        #expect(estimate.sampleCount == 5)
        #expect(estimate.medianWeeklyPercentPerWindow == 6)
    }

    @Test
    func `does not count a session whose reset is still in the future`() {
        let fixture = Self.historyFixture(burns: [5, 5])
        let now = fixture.currentSessionReset.addingTimeInterval(-3600)
        let futureReset = now.addingTimeInterval(30 * 60)
        let futureStart = futureReset.addingTimeInterval(-5 * 3600)
        let session = fixture.histories[0]
        let weekly = fixture.histories[1]
        let sessionEntries = (session.entries + [
            planEntry(at: futureStart.addingTimeInterval(3600), usedPercent: 80, resetsAt: futureReset),
        ]).sorted { $0.capturedAt < $1.capturedAt }
        let weeklyEntries = (weekly.entries + [
            planEntry(at: futureStart, usedPercent: 10, resetsAt: weekly.entries[0].resetsAt),
            planEntry(at: futureReset, usedPercent: 15, resetsAt: weekly.entries[0].resetsAt),
        ]).sorted { $0.capturedAt < $1.capturedAt }

        #expect(SessionEquivalentBurnEstimator.estimate(
            histories: [
                planSeries(name: .session, windowMinutes: 300, entries: sessionEntries),
                planSeries(name: .weekly, windowMinutes: 10080, entries: weeklyEntries),
            ],
            currentSessionResetsAt: nil,
            now: now) == nil)
    }

    @Test
    func `provider metric shows estimate only on its matching weekly window`() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let weeklyReset = now.addingTimeInterval((7 * 60 + 37) * 60)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 95,
                windowMinutes: 10080,
                resetsAt: weeklyReset,
                resetDescription: nil),
            updatedAt: now)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let forecast = SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 0.3,
            windowsUntilReset: 1,
            sampleCount: 7,
            weeklyResetsAt: weeklyReset,
            weeklyUsedPercent: 95)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            weeklyPace: UsagePace(
                stage: .onTrack,
                deltaPercent: -0.4,
                expectedUsedPercent: 95.4,
                actualUsedPercent: 95,
                etaSeconds: nil,
                willLastToReset: true),
            sessionEquivalentForecast: forecast,
            now: now))

        let sessionMetric = try #require(model.metrics.first { $0.id == "primary" })
        let weeklyMetric = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(sessionMetric.sessionEquivalentDetail == nil)
        #expect(weeklyMetric.percentLabel == "5% left")
        #expect(weeklyMetric.detailLeftText == "On pace")
        #expect(weeklyMetric.detailRightText == "Lasts until reset")
        #expect(weeklyMetric.sessionEquivalentDetail?.leftText == "Est. 0.3 session quota left")
        #expect(weeklyMetric.sessionEquivalentDetail?.rightText == "1 window until reset")
    }

    @MainActor
    @Test
    func `Claude scoped weekly window cannot use all model history`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let fixture = Self.historyFixture(burns: [4, 8, 6])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: fixture.histories)
        let now = fixture.currentSessionReset.addingTimeInterval(-3600)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: fixture.currentSessionReset,
            resetDescription: nil)
        let scopedOnly = UsageSnapshot(
            primary: session,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable weekly",
                    window: RateWindow(
                        usedPercent: 60,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(2 * 24 * 3600),
                        resetDescription: nil)),
            ],
            updatedAt: now)

        #expect(store.sessionEquivalentWindows(provider: .claude, snapshot: scopedOnly) == nil)

        let allModelsWeekly = RateWindow(
            usedPercent: 40,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil)
        let complete = UsageSnapshot(
            primary: session,
            secondary: allModelsWeekly,
            extraRateWindows: scopedOnly.extraRateWindows,
            updatedAt: now)
        let resolved = try #require(store.sessionEquivalentWindows(provider: .claude, snapshot: complete))
        #expect(resolved.weekly == allModelsWeekly)
        #expect(resolved.weeklyWindowID == nil)
    }

    @Test
    func `named provider metric requires the selected weekly window identity`() {
        let weekly = RateWindow(
            usedPercent: 60,
            windowMinutes: 10080,
            resetsAt: Self.weeklyReset,
            resetDescription: nil)
        let forecast = SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 4,
            windowsUntilReset: 9,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 60,
            weeklyWindowID: "antigravity-quota-summary-gemini-weekly")

        #expect(forecast.applies(
            to: weekly,
            windowID: "antigravity-quota-summary-gemini-weekly"))
        #expect(!forecast.applies(
            to: weekly,
            windowID: "antigravity-quota-summary-3p-weekly"))
    }

    @MainActor
    @Test
    func `usage store memoizes the history scan until revision changes`() {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let fixture = Self.historyFixture(burns: [4, 8, 6, 10])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: fixture.histories)
        store.planUtilizationHistoryRevision = 1
        let now = fixture.currentSessionReset.addingTimeInterval(-3600)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: fixture.currentSessionReset,
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 60,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil)

        #expect(store.sessionEquivalentForecast(
            provider: .claude,
            sessionWindow: session,
            weeklyWindow: weekly,
            now: now) != nil)
        #expect(store.sessionEquivalentForecast(
            provider: .claude,
            sessionWindow: session,
            weeklyWindow: weekly,
            now: now) != nil)
        #expect(store._sessionEquivalentHistoryScanCountForTesting == 1)

        store.planUtilizationHistoryRevision = 2
        #expect(store.sessionEquivalentForecast(
            provider: .claude,
            sessionWindow: session,
            weeklyWindow: weekly,
            now: now) != nil)
        #expect(store._sessionEquivalentHistoryScanCountForTesting == 2)
    }
}

extension SessionEquivalentForecastTests {
    @Test
    func `generic pair identity parser rejects overflowing component lengths`() {
        #expect(UsageStore.sessionEquivalentPairComponents(from: "\(Int.max)#x1#y") == nil)
    }

    static func historyFixture(burns: [Double])
        -> (histories: [PlanUtilizationSeriesHistory], currentSessionReset: Date)
    {
        self.historyFixture(samples: burns.map {
            (sessionUsedPercent: 100, weeklyBurnPercent: $0)
        })
    }

    private static func historyFixture(
        samples: [(sessionUsedPercent: Double, weeklyBurnPercent: Double)])
        -> (histories: [PlanUtilizationSeriesHistory], currentSessionReset: Date)
    {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let duration: TimeInterval = 5 * 3600
        let weeklyReset = start.addingTimeInterval(7 * 24 * 3600)
        var sessionEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyUsed = 0.0

        for (index, sample) in samples.enumerated() {
            let windowStart = start.addingTimeInterval(Double(index) * duration)
            let reset = windowStart.addingTimeInterval(duration)
            sessionEntries.append(planEntry(
                at: windowStart.addingTimeInterval(30 * 60),
                usedPercent: min(20, sample.sessionUsedPercent),
                resetsAt: reset))
            sessionEntries.append(planEntry(
                at: reset.addingTimeInterval(-30 * 60),
                usedPercent: sample.sessionUsedPercent,
                resetsAt: reset))
            weeklyEntries.append(planEntry(at: windowStart, usedPercent: weeklyUsed, resetsAt: weeklyReset))
            weeklyUsed += sample.weeklyBurnPercent
            weeklyEntries.append(planEntry(at: reset, usedPercent: weeklyUsed, resetsAt: weeklyReset))
        }

        return (
            histories: [
                planSeries(name: .session, windowMinutes: 300, entries: sessionEntries),
                planSeries(name: .weekly, windowMinutes: 10080, entries: weeklyEntries),
            ],
            currentSessionReset: start.addingTimeInterval(Double(samples.count + 1) * duration))
    }

    private static func alignedPartialHistoryFixture()
        -> (histories: [PlanUtilizationSeriesHistory], currentSessionReset: Date)
    {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let duration: TimeInterval = 5 * 3600
        let weeklyReset = start.addingTimeInterval(7 * 24 * 3600)
        let fullAllowanceBurn = 10.0
        var sessionEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyUsed = 0.0

        for (index, sessionUsedPercent) in [20.0, 40.0, 100.0].enumerated() {
            let windowStart = start.addingTimeInterval(Double(index) * duration)
            let reset = windowStart.addingTimeInterval(duration)
            let firstSessionUsedPercent = sessionUsedPercent / 4
            let firstCapturedAt = windowStart.addingTimeInterval(30 * 60)
            let lastCapturedAt = reset.addingTimeInterval(-30 * 60)
            let firstWeeklyUsedPercent = weeklyUsed + fullAllowanceBurn * firstSessionUsedPercent / 100
            let lastWeeklyUsedPercent = weeklyUsed + fullAllowanceBurn * sessionUsedPercent / 100

            sessionEntries.append(planEntry(
                at: firstCapturedAt,
                usedPercent: firstSessionUsedPercent,
                resetsAt: reset))
            weeklyEntries.append(planEntry(
                at: firstCapturedAt,
                usedPercent: firstWeeklyUsedPercent,
                resetsAt: weeklyReset))
            sessionEntries.append(planEntry(
                at: lastCapturedAt,
                usedPercent: sessionUsedPercent,
                resetsAt: reset))
            weeklyEntries.append(planEntry(
                at: lastCapturedAt,
                usedPercent: lastWeeklyUsedPercent,
                resetsAt: weeklyReset))
            weeklyUsed = lastWeeklyUsedPercent
        }

        let histories = UsageStore._updatedPlanUtilizationHistoriesForTesting(
            existingHistories: [],
            samples: [
                planSeries(name: .session, windowMinutes: 300, entries: sessionEntries),
                planSeries(name: .weekly, windowMinutes: 10080, entries: weeklyEntries),
            ]) ?? []
        return (
            histories: histories,
            currentSessionReset: start.addingTimeInterval(4 * duration))
    }

    private static func straddledBoundaryHistoryFixture()
        -> (histories: [PlanUtilizationSeriesHistory], currentSessionReset: Date)
    {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let duration: TimeInterval = 5 * 3600
        let stride: TimeInterval = 6 * 3600
        let weeklyReset = start.addingTimeInterval(7 * 24 * 3600)
        var sessionEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyUsed = 0.0

        for index in 0..<3 {
            let windowStart = start.addingTimeInterval(Double(index) * stride)
            let reset = windowStart.addingTimeInterval(duration)
            sessionEntries.append(planEntry(
                at: windowStart.addingTimeInterval(30 * 60),
                usedPercent: 20,
                resetsAt: reset))
            sessionEntries.append(planEntry(
                at: reset.addingTimeInterval(-30 * 60),
                usedPercent: 100,
                resetsAt: reset))
            weeklyEntries.append(planEntry(
                at: windowStart.addingTimeInterval(-90),
                usedPercent: weeklyUsed,
                resetsAt: weeklyReset))
            weeklyEntries.append(planEntry(
                at: windowStart.addingTimeInterval(30),
                usedPercent: weeklyUsed,
                resetsAt: weeklyReset))
            weeklyUsed += 10
            weeklyEntries.append(planEntry(
                at: reset.addingTimeInterval(-90),
                usedPercent: weeklyUsed,
                resetsAt: weeklyReset))
            weeklyEntries.append(planEntry(
                at: reset.addingTimeInterval(30),
                usedPercent: weeklyUsed,
                resetsAt: weeklyReset))
        }

        return (
            histories: [
                planSeries(name: .session, windowMinutes: 300, entries: sessionEntries),
                planSeries(name: .weekly, windowMinutes: 10080, entries: weeklyEntries),
            ],
            currentSessionReset: start.addingTimeInterval(3 * stride + duration))
    }
}
