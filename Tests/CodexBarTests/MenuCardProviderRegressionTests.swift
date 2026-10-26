import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MenuCardProviderRegressionTests {
    @Test
    func `menu card keeps positive sub percent usage visible`() {
        let metric = UsageMenuCardView.Model.Metric(
            id: "sub-percent",
            title: "Monthly",
            percent: 0.1,
            percentStyle: .used,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false)

        #expect(metric.percentLabel == "<1% used")
    }

    private static func contrastRatio(_ color: ProviderColor, againstLuminance background: Double) -> Double {
        let components = [color.red, color.green, color.blue].map { component in
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let foreground = 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
        return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
    }
}
