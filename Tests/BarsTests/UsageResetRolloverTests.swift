import BarsCore
import Foundation
import Testing
@testable import Bars

struct UsageResetRolloverTests {
    @Test
    func `a window past its reset reads as unused with no known reset`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = RateWindow(
            usedPercent: 66,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(-60),
            resetDescription: "Resets 3:10am",
            title: "Session")

        let rolledOver = window.rolledOver(at: now)

        #expect(rolledOver.usedPercent == 0)
        #expect(rolledOver.resetsAt == nil)
        #expect(rolledOver.resetDescription == nil)
        #expect(rolledOver.windowMinutes == 300)
        #expect(rolledOver.title == "Session")
    }

    @Test(arguments: [
        // Before its reset, without a reset, and a rolling-recovery window that restores only part at each tick.
        (60 as TimeInterval?, nil as Double?),
        (nil, nil),
        (-60, 10),
    ])
    func `other windows stay as reported`(resetOffset: TimeInterval?, nextRegenPercent: Double?) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = RateWindow(
            usedPercent: 66,
            windowMinutes: 300,
            resetsAt: resetOffset.map(now.addingTimeInterval),
            resetDescription: nil,
            nextRegenPercent: nextRegenPercent)

        #expect(window.rolledOver(at: now) == window)
    }

    @Test
    func `a snapshot rolls over only the windows whose reset passed`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let weeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 66,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(-60),
                resetDescription: nil),
            secondary: RateWindow(usedPercent: 54, windowMinutes: 10080, resetsAt: weeklyReset, resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "weekly-scoped",
                    title: "Sonnet only",
                    window: RateWindow(
                        usedPercent: 30,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(-1),
                        resetDescription: nil)),
            ],
            updatedAt: now.addingTimeInterval(-600))

        let rolledOver = snapshot.rollingOverResetWindows(at: now)

        #expect(rolledOver.primary?.usedPercent == 0)
        #expect(rolledOver.secondary == snapshot.secondary)
        #expect(rolledOver.extraRateWindows?.first?.window.usedPercent == 0)
        #expect(rolledOver.extraRateWindows?.first?.title == "Sonnet only")
        // The data is still as old as the fetch that produced it.
        #expect(rolledOver.updatedAt == snapshot.updatedAt)
        #expect(snapshot.earliestRolloverReset == now.addingTimeInterval(-60))
        #expect(rolledOver.earliestRolloverReset == weeklyReset)
        #expect(rolledOver.rollingOverResetWindows(at: now).secondary == rolledOver.secondary)
    }

    @Test(arguments: [0.2 as TimeInterval, -60])
    @MainActor
    func `the store rolls a published window over at its reset`(resetOffset: TimeInterval) async throws {
        let settings = testSettingsStore(suiteName: "UsageResetRolloverTests-store-\(resetOffset)")
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        defer { store.resetRolloverTask?.cancel() }
        let weeklyReset = Date().addingTimeInterval(60 * 60)
        store.snapshots[.claude] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 66,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(resetOffset),
                resetDescription: nil),
            secondary: RateWindow(usedPercent: 54, windowMinutes: 10080, resetsAt: weeklyReset, resetDescription: nil),
            updatedAt: Date())

        // Publishing the snapshot alone schedules the rollover.
        let deadline = Date().addingTimeInterval(5)
        while store.snapshots[.claude]?.primary?.usedPercent != 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.snapshots[.claude]?.primary?.usedPercent == 0)
        #expect(store.snapshots[.claude]?.secondary?.usedPercent == 54)
        // The next wake-up is the weekly reset.
        #expect(store.scheduledResetRolloverAt == weeklyReset)
    }
}
