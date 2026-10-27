import Foundation
import Testing
@testable import Bars
@testable import BarsCore

@Suite(.serialized)
@MainActor
struct SettingsStoreKeychainPreferenceTests {
    @Test
    func `ordinary settings fixtures own their keychain policy`() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            let first = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
            let second = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())

            #expect(!first.keychainAccessPolicy.isExplicitlyDisabled())
            first.debugDisableKeychainAccess = true
            #expect(first.keychainAccessPolicy.isExplicitlyDisabled())
            #expect(!second.keychainAccessPolicy.isExplicitlyDisabled())
            first.debugDisableKeychainAccess = false
            #expect(!first.keychainAccessPolicy.isExplicitlyDisabled())
            #expect(KeychainAccessGate.isDisabled)
        }
    }

    @Test(arguments: [nil, false, true] as [Bool?], [nil, false, true] as [Bool?])
    func `local keychain preference wins and shared defaults fill only an absent value`(
        localValue: Bool?, sharedValue: Bool?)
    {
        let local = InMemoryUserDefaults()
        let shared = InMemoryUserDefaults()
        if let localValue {
            local.set(localValue, forKey: "debugDisableKeychainAccess")
        }
        if let sharedValue {
            shared.set(sharedValue, forKey: "debugDisableKeychainAccess")
        }

        let disabled = SettingsStore.loadDebugDisableKeychainAccess(userDefaults: local, sharedDefaults: shared)

        #expect(disabled == (localValue ?? sharedValue ?? false))
        #expect(local.object(forKey: "debugDisableKeychainAccess") as? Bool == (localValue ?? sharedValue))
        #expect(shared.object(forKey: "debugDisableKeychainAccess") as? Bool == sharedValue)
    }

    @Test
    func `ordinary tests never invoke the shared defaults resolver`() throws {
        try #require(SettingsStore.isRunningTests)
        var resolutions = 0
        let shared = SettingsStore.resolveSharedDefaults {
            resolutions += 1
            return InMemoryUserDefaults()
        }

        #expect(shared == nil)
        #expect(resolutions == 0)
        #expect(SettingsStore.sharedDefaults == nil)
        let local = InMemoryUserDefaults()
        #expect(!SettingsStore.shouldBridgeSharedDefaults(for: local))
        #expect(!SettingsStore.loadDebugDisableKeychainAccess(userDefaults: local))
        #expect(local.dictionaryRepresentation().isEmpty)
    }

    @Test(arguments: [false, true])
    func `settings initialization isolates shared defaults and keychain policy`(disabled: Bool) throws {
        let local = InMemoryUserDefaults()
        local.set(disabled, forKey: "debugDisableKeychainAccess")
        var keychainAccessValues: [Bool] = []
        let keychainAccessPolicy = SettingsStoreKeychainAccessPolicy(
            setDisabled: { keychainAccessValues.append($0) },
            isExplicitlyDisabled: { keychainAccessValues.last ?? false })
        try self.withSettingsStore(
            defaults: local,
            keychainAccessPolicy: keychainAccessPolicy)
        { store in
            #expect(local.object(forKey: "widgetSelectedProvider") == nil)
            #expect(store.debugDisableKeychainAccess == disabled)
            #expect(store.refreshFrequency == .adaptive)
            // Config/secret migration remains independent of app-group migration.
            #expect(local.bool(forKey: "bars.legacySecretsMigrationCompleted") == !disabled)

            store.debugDisableKeychainAccess = !disabled
            #expect(local.bool(forKey: "debugDisableKeychainAccess") == !disabled)
            store.debugDisableKeychainAccess = disabled
            #expect(local.bool(forKey: "debugDisableKeychainAccess") == disabled)
            #expect(SettingsStore.sharedDefaults == nil)
            #expect(keychainAccessValues == [disabled, disabled, !disabled, disabled])
        }
    }

    @Test
    func `existing launch marker still keeps the legacy refresh default`() throws {
        let local = InMemoryUserDefaults()
        local.set(1, forKey: "providerDetectionCompleted")
        try self.withSettingsStore(defaults: local) { store in
            #expect(store.refreshFrequency == .fiveMinutes)
            #expect(local.integer(forKey: "providerDetectionCompleted") == 1)
        }
    }

    private func withSettingsStore(
        defaults: InMemoryUserDefaults,
        config: BarsConfig? = nil,
        keychainAccessPolicy: SettingsStoreKeychainAccessPolicy = SettingsStoreKeychainAccessPolicy(
            setDisabled: { _ in },
            isExplicitlyDisabled: { false }),
        operation: (SettingsStore) throws -> Void) throws
    {
        // Fail before constructing settings if the caller deliberately opted into live user state.
        try #require(SettingsStore.isRunningTests)
        try #require(KeychainTestSafety.resolveShouldBlockRealKeychainAccess(
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment))
        try #require(!KeychainAccessGate.isDisabledByEnvironment())
        try #require(KeychainAccessGate.processDisableReason == nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreKeychainPreferenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Could not remove synthetic settings fixture: \(error)")
            }
        }
        let configStore = BarsConfigStore(fileURL: root.appendingPathComponent("config.json"))
        if let config { try configStore.save(config) }
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            claudeCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            tokenAccountStore: InMemoryTokenAccountStore(fileURL: root.appendingPathComponent("accounts.json")),
            keychainAccessPolicy: keychainAccessPolicy,
            performInitialProviderDetection: false)
        defer { store.configFileWatcher?.stop() }
        try operation(store)
    }
}
