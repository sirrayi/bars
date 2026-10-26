import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AutomaticQuotaSnapshotTests {
    @Test
    func `automatic uses a busy weekly quota instead of an empty session`() {
        let snapshot = UsageSnapshot(
            primary: Self.window(used: 0, minutes: 300),
            secondary: Self.window(used: 90, minutes: 10080),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let selected = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: .claude, snapshot: snapshot, supportsAverage: false)

        #expect(selected == snapshot.secondary)
    }

    private static func window(used: Double, minutes: Int, reset: Date? = nil) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: reset, resetDescription: nil)
    }
}
