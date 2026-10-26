import AppKit
import Foundation
import Testing
@testable import CodexBar

@Suite("TerminalApp")
struct TerminalAppTests {
    @Test
    @MainActor
    func `default is terminal`() throws {
        let suite = "TerminalAppTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        #expect(store.terminalApp == .terminal)
    }

    @Test
    @MainActor
    func `setting terminal app persists it`() throws {
        let suite = "TerminalAppTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        store.terminalApp = .iTerm
        #expect(store.terminalApp == .iTerm)
        #expect(defaults.string(forKey: "terminalApp") == "iTerm")
    }

    @Test
    @MainActor
    func `invalid stored value falls back to terminal`() throws {
        let suite = "TerminalAppTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("nonexistent", forKey: "terminalApp")
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        #expect(store.terminalApp == .terminal)
    }

    @Test
    @MainActor
    func `picker icon has compact intrinsic size`() {
        let source = NSImage(size: NSSize(width: 128, height: 64))

        let icon = TerminalApp.pickerIcon(from: source)

        #expect(icon.size == NSSize(width: 16, height: 16))
    }

    @Test
    @MainActor
    func `zero size picker icon remains compact`() {
        let icon = TerminalApp.pickerIcon(from: NSImage(size: .zero))

        #expect(icon.size == NSSize(width: 16, height: 16))
    }

    @Test
    func `all cases have unique bundle identifiers`() {
        let ids = TerminalApp.allCases.map(\.bundleIdentifier)
        #expect(Set(ids).count == TerminalApp.allCases.count)
    }

    @Test
    func `all cases have non-empty labels`() {
        for app in TerminalApp.allCases {
            #expect(!app.label.isEmpty)
        }
    }

    @Test
    func `round-trip all cases through raw value`() {
        for app in TerminalApp.allCases {
            #expect(TerminalApp(rawValue: app.rawValue) == app)
        }
    }

    @Test
    func `escapes commands embedded in AppleScript strings`() {
        let escaped = TerminalApp.escapeForAppleScript(#"echo "C:\tmp""#)

        #expect(escaped == #"echo \"C:\\tmp\""#)
    }

    @Test
    func `escapes every TOML basic string control character`() {
        let value = "a\u{8}\t\n\u{c}\r\"\\\u{1}\u{7f}é"

        #expect(TerminalApp.escapeForTOML(value) == #"a\b\t\n\f\r\"\\\u0001\u007Fé"#)
    }

    @Test
    func `builds a Warp tab config for one terminal pane`() {
        let config = TerminalApp.warpTabConfig(
            name: "codexbar_test",
            command: "printf \"hello\"\nnext",
            directory: #"/tmp/dir "quoted"\child"#)

        #expect(config == WarpTerminalConfig.marker + #"""
        name = "codexbar_test"

        [[panes]]
        id = "main"
        type = "terminal"
        directory = "/tmp/dir \"quoted\"\\child"
        commands = ["printf \"hello\"\nnext"]
        """#)
    }

    @Test
    @MainActor
    func `successful alternate launch does not fall back`() async {
        var scripts: [String] = []
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: Self.temporaryHome(),
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/iTerm.app") },
            identifier: { UUID() },
            executeAppleScript: {
                scripts.append($0)
                return true
            },
            open: { _, _, _ in Issue.record("open should not run") },
            scheduleCleanup: { _, _ in Issue.record("cleanup should not be scheduled") })

        let result = await TerminalLauncher(dependencies: dependencies).launch(.iTerm, command: "claude")

        #expect(result == .selected)
        #expect(scripts.count == 1)
        #expect(scripts[0].contains(#"tell application "iTerm""#))
    }

    @Test
    @MainActor
    func `Terminal failure does not recurse`() async {
        var scriptCount = 0
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: Self.temporaryHome(),
            applicationURL: { _ in nil },
            identifier: { UUID() },
            executeAppleScript: { _ in
                scriptCount += 1
                return false
            },
            open: { _, _, _ in Issue.record("open should not run") },
            scheduleCleanup: { _, _ in Issue.record("cleanup should not be scheduled") })

        let result = await TerminalLauncher(dependencies: dependencies).launch(.terminal, command: "claude")

        #expect(result == .failed)
        #expect(scriptCount == 1)
    }

    @Test
    @MainActor
    func `failed alternate and Terminal each launch exactly once`() async {
        var scripts: [String] = []
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: Self.temporaryHome(),
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/iTerm.app") },
            identifier: { UUID() },
            executeAppleScript: {
                scripts.append($0)
                return false
            },
            open: { _, _, _ in Issue.record("open should not run") },
            scheduleCleanup: { _, _ in Issue.record("cleanup should not be scheduled") })

        let result = await TerminalLauncher(dependencies: dependencies).launch(.iTerm, command: "claude")

        #expect(result == .failed)
        #expect(scripts.count == 2)
        #expect(scripts[0].contains(#"tell application "iTerm""#))
        #expect(scripts[1].contains(#"tell application "Terminal""#))
    }

    private static func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalAppTests-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
private final class UUIDSequence {
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        self.values.removeFirst()
    }
}

private enum TestLaunchError: Error {
    case failed
}
