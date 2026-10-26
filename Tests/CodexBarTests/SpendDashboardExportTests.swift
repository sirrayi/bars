import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct SpendDashboardExportTests {
    @Test
    func `export filename uses the selected window`() {
        #expect(SpendDashboardJSONExporter.defaultFilename(days: 7) == "codexbar-spend-last-7-days.json")
        #expect(SpendDashboardJSONExporter.defaultFilename(days: 30) == "codexbar-spend-last-30-days.json")
        #expect(
            SpendDashboardJSONExporter.defaultFilename(days: SpendDashboardSource.scanDays)
                == "codexbar-spend-all-time.json")
    }
}
