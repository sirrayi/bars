import AppKit
import Foundation
import Testing
@testable import Bars
@testable import BarsCore

struct SpendDashboardExportTests {
    @Test
    func `export filename uses the selected window`() {
        #expect(SpendDashboardJSONExporter.defaultFilename(days: 7) == "bars-spend-last-7-days.json")
        #expect(SpendDashboardJSONExporter.defaultFilename(days: 30) == "bars-spend-last-30-days.json")
        #expect(
            SpendDashboardJSONExporter.defaultFilename(days: SpendDashboardSource.scanDays)
                == "bars-spend-all-time.json")
    }
}
