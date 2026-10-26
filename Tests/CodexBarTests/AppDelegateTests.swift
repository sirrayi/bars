import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct AppDelegateTests {
    @Test
    func `refuses the untitled window macOS would fill with the empty Settings scene`() {
        _ = NSApplication.shared
        let appDelegate = AppDelegate()

        #expect(appDelegate.applicationShouldOpenUntitledFile(NSApplication.shared) == false)
    }
}

@MainActor
private final class DummyStatusController: StatusItemControlling {
    private(set) var shutdowns = 0
    private(set) var didSetSettingsOpenHandler = false

    func setSettingsOpenHandler(_: @escaping @MainActor (SettingsPane?) -> Void) {
        self.didSetSettingsOpenHandler = true
    }

    func openMenuFromShortcut() {}
    func runLoginFlowFromSettings(provider _: UsageProvider) async {}
    func prepareForAppShutdown() {
        self.shutdowns += 1
    }
}
