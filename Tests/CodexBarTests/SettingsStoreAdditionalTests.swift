import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreAdditionalTests {
    @Test
    func `settings fixtures with the same label keep independent persisted values`() {
        let first = Self.makeSettingsStore(suite: #function)
        first.refreshFrequency = .fifteenMinutes

        // A second invocation used to erase the first fixture's persisted domain.
        let second = Self.makeSettingsStore(suite: #function)
        second.refreshFrequency = .thirtyMinutes

        #expect(first.userDefaults.string(forKey: "refreshFrequency") == RefreshFrequency.fifteenMinutes.rawValue)
        #expect(second.userDefaults.string(forKey: "refreshFrequency") == RefreshFrequency.thirtyMinutes.rawValue)
        #expect(first.configStore.fileURL != second.configStore.fileURL)

        second.userDefaults.removeObject(forKey: "refreshFrequency")
        #expect(first.userDefaults.string(forKey: "refreshFrequency") == RefreshFrequency.fifteenMinutes.rawValue)
    }

    @Test
    func `token accounts set manual cookie source when required`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-token-accounts")

        settings.addTokenAccount(provider: .claude, label: "Primary", token: "token-1")

        #expect(settings.tokenAccounts(for: .claude).count == 1)
        #expect(settings.claudeCookieSource == .manual)
    }

    @Test
    func `detects token cost usage sources from filesystem`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let jsonl = sessions.appendingPathComponent("usage.jsonl")
        try Data("{}".utf8).write(to: jsonl)
        defer { try? fm.removeItem(at: root) }

        let env = ["CODEX_HOME": root.path]

        #expect(SettingsStore.hasAnyTokenCostUsageSources(env: env, fileManager: fm))
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        testSettingsStore(suiteName: suite, userDefaults: InMemoryUserDefaults())
    }
}

extension SettingsStoreAdditionalTests {}

extension SettingsStoreAdditionalTests {}

extension SettingsStoreAdditionalTests {}
