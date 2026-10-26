import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemQuotaWarningFlashTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        NSStatusBar.system
    }

    @Test
    func `quota warning flash state lasts for configured duration`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemQuotaWarningFlashTests-duration"))
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual

        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let now = Date()
        controller.startQuotaWarningFlash(provider: .claude, postedAt: now)

        #expect(controller.quotaWarningFlashActive(provider: .claude, now: now.addingTimeInterval(59)) == true)
        #expect(controller.quotaWarningFlashActive(provider: .claude, now: now.addingTimeInterval(61)) == false)
    }

    @Test
    func `quota warning flash image draws non template red overlay`() throws {
        let size = NSSize(width: 16, height: 16)
        let base = NSImage(size: size)
        base.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        base.unlockFocus()
        base.isTemplate = true

        let output = StatusItemController.quotaWarningFlashImage(base: base)
        let outputData = try #require(output.tiffRepresentation)
        let outputRep = try #require(NSBitmapImageRep(data: outputData))
        let center = try #require(outputRep.colorAt(x: 8, y: 8))

        #expect(output.isTemplate == false)
        #expect(center.redComponent > center.blueComponent)
    }
}
