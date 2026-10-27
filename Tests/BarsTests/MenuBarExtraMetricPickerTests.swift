import AppKit
import BarsCore
import Foundation
import SwiftUI
import Testing
@testable import Bars

struct MenuBarExtraMetricPickerTests {
    @Test
    func `metric table offers each provider owned named allowance before fetching`() {
        for descriptor in ProviderDescriptorRegistry.all {
            let labels = MenuBarPercentWindowPreference.available(for: descriptor.id)
                .map { $0.label(for: descriptor.id) }
            for title in descriptor.menuBarMetrics.namedExtras.values {
                #expect(labels.contains(title))
            }
        }
        #expect(!MenuBarPercentWindowPreference.available(for: .opencode)
            .map { $0.label(for: .opencode) }.contains("Grok Bot"))
    }

    @Test
    func `the picker leaves an independent spend percent untouched`() {
        let spend = MenuBarLayoutToken.percent(window: .spend)
        let layout = MenuBarLayout(lines: [[.percent(window: .session), spend, .percent(window: .weekly)]])
        #expect(MenuBarPercentWindowPreference.current(in: layout) == nil)
        #expect(MenuBarPercentWindowPreference.automatic.applied(to: layout).lines == [[
            .percent(window: .automatic), spend, .percent(window: .automatic),
        ]])

        let single = MenuBarLayout(lines: [[.icon, .percent(window: .session), spend]])
        #expect(MenuBarPercentWindowPreference.current(in: single) == .session)
        #expect(MenuBarPercentWindowPreference.weekly.applied(to: single).lines == [[
            .icon, .percent(window: .weekly), spend,
        ]])

        // With no ordinary percentage there is nothing for the picker to control or to take over.
        let spendOnly = MenuBarLayout(lines: [[.icon, spend]])
        #expect(MenuBarPercentWindowPreference.current(in: spendOnly) == nil)
        #expect(!MenuBarPercentWindowPreference.hasPercentToken(in: spendOnly))
        for preference in MenuBarPercentWindowPreference.available(for: .claude, layout: spendOnly) {
            #expect(preference.applied(to: spendOnly) == spendOnly)
        }
        #expect(!MenuBarPercentWindowPreference.available(for: .claude).contains { preference in
            preference.label(for: .claude) == L("Spend")
        })
    }
}
