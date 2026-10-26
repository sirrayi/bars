import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class SpendStackedChartsNativeProofTests: XCTestCase {
    private func verifyOffsets(_ points: [(start: Double, end: Double, cost: Double)]) {
        var end = 0.0
        for point in points {
            XCTAssertEqual(point.start, end, accuracy: 0.000_001)
            XCTAssertEqual(point.end - point.start, point.cost, accuracy: 0.000_001)
            end = point.end
        }
    }
}

private struct StackedChartProofView: View {
    let group: SpendDashboardModel.CurrencyGroup
    let phase: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(self.phase.capitalized): daily and hourly stacked spend").font(.headline)
            Text("Synthetic data · three providers · zero and thin segments").font(.caption)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack {
                        SpendDashboardCurrencySection(group: self.group, requestedDays: 7, hidePersonalInfo: true)
                        Color.clear.frame(height: 1).id("charts-bottom")
                    }
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(250))
                    proxy.scrollTo("charts-bottom", anchor: .bottom)
                }
            }
        }
        .padding(20)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.timeZone, .gmt)
        .preferredColorScheme(.light)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
