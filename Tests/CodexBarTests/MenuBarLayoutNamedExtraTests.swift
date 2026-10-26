import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MenuBarLayoutNamedExtraTests {
    private func snapshot(used: Double, primaryUsed: Double = 10) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: primaryUsed, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "cursor-grok-bot",
                title: "Grok Bot",
                window: RateWindow(usedPercent: used, windowMinutes: nil, resetsAt: nil, resetDescription: nil))],
            updatedAt: Date(timeIntervalSince1970: 100))
    }
}
