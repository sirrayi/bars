import Foundation
import Testing
@testable import Bars
@testable import BarsCore

@MainActor
struct SessionUsagePresentationTests {
    @Test
    func `search finds a named conversation case insensitively without changing accounting`() {
        let session = Self.session(id: "thread-alpha", title: "Fix cache accounting")
        let original = session
        let matches = SessionUsagePresentation.sessions([session], matching: "  CACHE  ", hidePersonalInfo: false)
        #expect(matches == [original])
        #expect(session == original)
    }

    @Test
    func `search keeps IDs available but cannot reveal hidden conversation names`() {
        let session = Self.session(id: "thread-alpha", title: "Confidential customer incident")
        #expect(SessionUsagePresentation.sessions(
            [session],
            matching: "customer",
            hidePersonalInfo: true).isEmpty)
        #expect(SessionUsagePresentation.sessions(
            [session],
            matching: "ALPHA",
            hidePersonalInfo: true) == [session])
    }

    @Test
    func `search considers all retained conversations before ordering`() {
        let sessions = (0..<120).map { Self.session(id: "thread-\($0)", title: "Conversation \($0)") }
        #expect(SessionUsagePresentation.sessions(sessions, matching: "", hidePersonalInfo: false).count == 120)
        #expect(SessionUsagePresentation.sessions(
            sessions,
            matching: "Conversation 119",
            hidePersonalInfo: false).map(\.sessionID) == ["thread-119"])
    }

    @Test
    func `conversations are ordered by recency with a stable tie break`() {
        let oldest = Self.session(id: "old", activity: 1)
        let latestB = Self.session(id: "b", activity: 2)
        let latestA = Self.session(id: "a", activity: 2)
        #expect(SessionUsagePresentation.sessions(
            [oldest, latestB, latestA],
            matching: "",
            hidePersonalInfo: false).map(\.sessionID) == ["a", "b", "old"])
    }

    @Test
    func `uncached input excludes cache hits and does not add reasoning again`() {
        let session = Self.session(id: "example")
        #expect(SessionUsagePresentation.uncachedInput(session) == 30)
        #expect(session.inputTokens == 120)
        #expect(session.cachedInputTokens == 90)
        #expect(session.outputTokens == 20)
        #expect(session.reasoningTokens == 10)
        #expect(session.totalTokens == 140)
    }

    @Test
    func `unknown or inconsistent cached input stays unavailable instead of becoming zero`() {
        #expect(SessionUsagePresentation.uncachedInput(Self.session(id: "missing", cached: nil)) == nil)
        #expect(SessionUsagePresentation.uncachedInput(Self.session(id: "invalid", cached: 121)) == nil)
        #expect(SessionUsagePresentation.uncachedInput(Self.session(id: "all-cached", cached: 120)) == 0)
    }

    @Test
    func `cost conversion preserves unknown zero and source currency semantics`() {
        #expect(SessionUsagePresentation.convertedCost(nil, multiplier: 2) == nil)
        #expect(SessionUsagePresentation.convertedCost(0, multiplier: 2) == 0)
        #expect(SessionUsagePresentation.convertedCost(3, multiplier: 2) == 6)
        #expect(SessionUsagePresentation.convertedCost(.infinity, multiplier: 1) == nil)
        #expect(SessionUsagePresentation.convertedCost(3, multiplier: .infinity) == nil)
        #expect(SessionUsagePresentation.costText(0.0001, multiplier: 1, currencyCode: "USD") == "$0.0001")
        #expect(SessionUsagePresentation.costText(0, multiplier: 1, currencyCode: "USD") == "$0.00")
        #expect(SessionUsagePresentation.costText(0.0000001, multiplier: 1, currencyCode: "USD") == "<$0.000001")
    }

    @Test
    func `token and cost sorting supports both directions with unknown values last`() {
        let sessions = [
            Self.session(id: "unknown", total: nil, cost: nil),
            Self.session(id: "large", total: 1000, cost: 0),
            Self.session(id: "small", total: 10, cost: 2),
        ]
        for (order, ascending, expected) in [
            (SessionUsagePresentation.Sort.tokens, false, ["large", "small", "unknown"]),
            (.tokens, true, ["small", "large", "unknown"]),
            (.cost, false, ["small", "large", "unknown"]),
            (.cost, true, ["large", "small", "unknown"]),
        ] {
            #expect(SessionUsagePresentation.sessions(
                sessions,
                matching: "",
                hidePersonalInfo: false,
                sort: order,
                ascending: ascending)
                .map(\.sessionID) == expected)
        }
    }

    @Test
    func `sorting rejects invalid values and resolves ties by recent activity`() {
        let sessions = [
            Self.session(id: "invalid", total: -1, cost: .infinity),
            Self.session(id: "old", activity: 1),
            Self.session(id: "new", activity: 2),
        ]
        for order in [SessionUsagePresentation.Sort.tokens, .cost] {
            #expect(SessionUsagePresentation.sessions(
                sessions,
                matching: "",
                hidePersonalInfo: false,
                sort: order,
                ascending: true)
                .map(\.sessionID) == ["new", "old", "invalid"])
        }
    }

    @Test
    func `tool activity uses the same reporting days and excludes the following midnight`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15)))
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 2,
            daily: [],
            updatedAt: now)
        let range = SessionUsagePresentation.toolActivityRange(snapshot: snapshot, calendar: calendar)
        #expect(calendar.component(.day, from: range.lowerBound) == 20)
        #expect(calendar.component(.hour, from: range.lowerBound) == 0)
        #expect(calendar.component(.day, from: range.upperBound) == 22)
        #expect(range.contains(now))
        #expect(!range.contains(range.upperBound))
    }

    private static func session(
        id: String,
        title: String? = nil,
        activity: TimeInterval = 1,
        cached: Int? = 90,
        total: Int? = 140,
        cost: Double? = 0.02) -> CostUsageSessionBreakdown
    {
        CostUsageSessionBreakdown(
            sessionID: id,
            lastActivity: Date(timeIntervalSince1970: activity),
            inputTokens: 120,
            cachedInputTokens: cached,
            outputTokens: 20,
            reasoningTokens: 10,
            totalTokens: total,
            requestCount: 2,
            costUSD: cost,
            modelBreakdowns: [],
            title: title)
    }
}
