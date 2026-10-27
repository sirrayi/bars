import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3
import Testing
@testable import Bars
@testable import BarsCore
@testable import SweetCookieKit

@Suite(.serialized)
struct BrowserCookiePromptContractTests {
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var interactive = 0
        private let promptFreeServices: Set<String>
        private let deniesInteraction: Bool

        init(promptFreeBrowser: Browser? = nil, deniesInteraction: Bool = false) {
            self.deniesInteraction = deniesInteraction
            self.promptFreeServices = Set(promptFreeBrowser?.safeStorageLabels.map(\.service) ?? [])
        }

        var interactiveQueries: Int {
            self.lock.withLock { self.interactive }
        }

        func lookup(_ service: String, _ account: String, _ allowInteraction: Bool) -> (OSStatus, String?) {
            self.lock.withLock {
                if self.promptFreeServices.contains(service) {
                    return (errSecSuccess, "synthetic-safe-storage-password")
                }
                guard allowInteraction else { return (errSecInteractionNotAllowed, nil) }
                self.interactive += 1
                if self.deniesInteraction { return (errSecAuthFailed, nil) }
                return (errSecSuccess, "synthetic-safe-storage-password")
            }
        }
    }

    private func withFakeKeychain<T>(_ operation: () throws -> T) rethrows -> T {
        BrowserCookieAccessGate.resetForTesting()
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        let wasDisabled = BrowserCookieKeychainAccessGate.isDisabled
        let promptHandler = BrowserCookieKeychainPromptHandler.handler
        BrowserCookieKeychainAccessGate.isDisabled = false
        BrowserCookieKeychainPromptHandler.handler = nil
        defer {
            BrowserCookieKeychainAccessGate.isDisabled = wasDisabled
            BrowserCookieKeychainPromptHandler.handler = promptHandler
            BrowserCookieAccessGate.resetForTesting()
            ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        }
        return try KeychainAccessGate.withTaskOverrideForTesting(false, operation: operation)
    }

    private static func readKey(for browser: Browser, keychain: FakeKeychain) throws -> Data {
        try BrowserCookieAccessGate.withRecordReadInteractionPolicy {
            do {
                return try ChromeCookieImporter.chromeSafeStorageKey(for: browser, passwordLookup: keychain.lookup)
            } catch let error as ChromeCookieImporter.ImportError {
                throw BrowserCookieError.mapChromeError(error, browser: browser)
            }
        }
    }

    @Test(arguments: [Browser.brave, .claudeDesktop])
    func `unrelated cookie rows never request a Safe Storage key`(browser: Browser) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(
            db,
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); INSERT INTO meta VALUES ('version', '24'); " +
                "CREATE TABLE cookies (host_key TEXT, name TEXT, path TEXT, expires_utc INTEGER, " +
                "is_secure INTEGER, is_httponly INTEGER, value TEXT, encrypted_value BLOB); " +
                "INSERT INTO cookies VALUES ('unrelated.example', 'session', '/', 0, 1, 1, '', X'763130')",
            nil,
            nil,
            nil) == SQLITE_OK)
        let store = BrowserCookieStore(
            browser: browser,
            profile: .init(id: home.path, name: "Synthetic"),
            kind: .network,
            label: "Synthetic Brave",
            databaseURL: database)
        let client = BrowserCookieClient(configuration: .init(homeDirectories: [home]))
        try self.withFakeKeychain {
            // If host filtering ever reaches Safe Storage, fail before any real credential read.
            BrowserCookieKeychainAccessGate.isDisabled = true
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                try ProviderInteractionContext.$current.withValue(.background) {
                    let records = try client.barsRecords(
                        matching: BrowserCookieQuery(domains: ["xiaomimimo.com"], domainMatch: .exact), in: store)
                    #expect(records.isEmpty)
                }
            }
        }
    }

    @Test
    func `every provider browser order keeps background key reads noninteractive`() {
        let keychain = FakeKeychain()
        self.withFakeKeychain {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                ProviderInteractionContext.$current.withValue(.background) {
                    BrowserCookieAccessGate.withExplicitRetry {
                        for descriptor in ProviderDescriptorRegistry.all {
                            for browser in descriptor.metadata.browserCookieOrder ?? []
                                where browser.usesKeychainForCookieDecryption
                            {
                                #expect(BrowserCookieAccessGate.shouldAttempt(browser))
                                #expect(throws: BrowserCookieError.self) {
                                    try Self.readKey(for: browser, keychain: keychain)
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(keychain.interactiveQueries == 0)
    }

    private final class NativeBrowserFixture: @unchecked Sendable {
        let home: URL
        let detection: BrowserDetection
        let keychain = FakeKeychain(promptFreeBrowser: .chrome)
        let reads = LockIsolated<[Browser]>([])
        let validated = LockIsolated<[String]>([])
        let events = LockIsolated<[String]>([])

        init() throws {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.home = home
            let key = try ChromeCookieImporter.chromeSafeStorageKey(
                for: .chrome, passwordLookup: FakeKeychain(promptFreeBrowser: .chrome).lookup)
            ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
            for browser in [Browser.chrome, .brave] {
                let relative = try #require(browser.chromiumProfileRelativePath)
                let directory = home.appendingPathComponent("Library/Application Support/\(relative)/Default/Network")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var db: OpaquePointer?
                #expect(sqlite3_open(directory.appendingPathComponent("Cookies").path, &db) == SQLITE_OK)
                defer { sqlite3_close(db) }
                #expect(try sqlite3_exec(
                    db,
                    "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); " +
                        "INSERT INTO meta VALUES ('version', '24'); " +
                        "CREATE TABLE cookies (host_key TEXT, name TEXT, path TEXT, expires_utc INTEGER, " +
                        "is_secure INTEGER, is_httponly INTEGER, value TEXT, encrypted_value BLOB); " +
                        [
                            ("venice.ai", "__session"),
                            ("grok.com", "sso"),
                            ("replicate.com", "sessionid"),
                            ("github.com", "user_session"),
                            ("admin.mistral.ai", "ory_session_fixture"),
                        ].map { domain, name in
                            let encrypted = try Self.encrypt(browser.rawValue, domain: domain, key: key)
                            return "INSERT INTO cookies VALUES ('\(domain)', '\(name)', '/', 0, 1, 1, " +
                                "'', X'\(encrypted)');"
                        }.joined(),
                    nil,
                    nil,
                    nil) == SQLITE_OK)
            }
            self.detection = BrowserDetection(
                homeDirectory: home.path,
                cacheTTL: 0,
                now: Date.init,
                fileExists: { path in
                    [Browser.chrome, .brave].contains { path == "/Applications/\($0.appBundleName).app" }
                        || (path.hasPrefix(home.path) && FileManager.default.fileExists(atPath: path))
                },
                directoryContents: { try? FileManager.default.contentsOfDirectory(atPath: $0) },
                applicationURLs: { _ in [] },
                profileAccessIssue: { _ in nil })
        }

        deinit { try? FileManager.default.removeItem(at: self.home) }

        func records(_ browser: Browser, _ query: BrowserCookieQuery, _ logger: ((String) -> Void)?) throws
            -> [BrowserCookieStoreRecords]
        {
            let client = BrowserCookieClient(configuration: .init(homeDirectories: [self.home]))
            // Safari advertises a placeholder store even when this synthetic home has no Safari database.
            let stores = try client.barsStores(for: browser).filter { $0.databaseURL != nil }
            guard !stores.isEmpty else { return [] }
            self.reads.setValue(self.reads.value + [browser])
            self.events.setValue(self.events.value + ["read:\(browser.rawValue)"])
            return try stores.map { store in
                let records = try ChromeCookieImporter.loadCookies(
                    from: store,
                    matchingDomains: query.domains,
                    domainMatch: query.domainMatch,
                    safeStorageKey: { try BrowserCookiePromptContractTests.readKey(for: $0, keychain: self.keychain) })
                return BrowserCookieStoreRecords(
                    store: store, records: records.map(BrowserCookieClient.makeBrowserCookieRecord))
            }
        }

        private static func encrypt(_ value: String, domain: String, key: Data) throws -> String {
            let plaintext = Data(SHA256.hash(data: Data(domain.utf8))) + Data(value.utf8)
            let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
            var output = Data(count: plaintext.count + kCCBlockSizeAES128)
            let capacity = output.count
            var written = 0
            let result = output.withUnsafeMutableBytes { out in
                plaintext.withUnsafeBytes { input in
                    key.withUnsafeBytes { key in
                        iv.withUnsafeBytes { iv in
                            CCCrypt(
                                CCOperation(kCCEncrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress,
                                kCCKeySizeAES128,
                                iv.baseAddress,
                                input.baseAddress,
                                plaintext.count,
                                out.baseAddress,
                                capacity,
                                &written)
                        }
                    }
                }
            }
            try #require(result == kCCSuccess)
            return (Data("v10".utf8) + output.prefix(written)).map { String(format: "%02x", $0) }.joined()
        }

        func accepts(_ header: String, rejectingChrome: Bool) -> Bool {
            self.validated.setValue(self.validated.value + [header])
            self.events.setValue(self.events.value + ["validate:\(header)"])
            return !rejectingChrome || header.contains("brave")
        }
    }

    @Test(arguments: [Browser.brave, .claudeDesktop])
    func `prompt free reads preserve the allowance and nested imports share it`(browser: Browser) throws {
        let keychain = FakeKeychain(promptFreeBrowser: .chrome)
        try self.withFakeKeychain {
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                try ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try BrowserCookieAccessGate.withExplicitRetry {
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                        #expect(keychain.interactiveQueries == 0)
                        try BrowserCookieAccessGate.withExplicitRetry {
                            _ = try Self.readKey(for: browser, keychain: keychain)
                        }
                        #expect(keychain.interactiveQueries == 1)
                        #expect(throws: BrowserCookieError.self) { try Self.readKey(for: .arc, keychain: keychain) }
                        #expect(throws: BrowserCookieError.self) { try Self.readKey(for: .edge, keychain: keychain) }
                    }
                }
            }
        }
        #expect(keychain.interactiveQueries == 1)
    }

    @Test
    func `a failed background read does not impose a denial cooldown`() throws {
        let keychain = FakeKeychain()
        try self.withFakeKeychain {
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                ProviderInteractionContext.$current.withValue(.background) {
                    do {
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                        Issue.record("Expected a no-UI read failure")
                    } catch {
                        BrowserCookieAccessGate.recordIfNeeded(error)
                    }
                }
                #expect(!BrowserCookieAccessGate.hasActiveDenial(for: .chrome))
                try ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try BrowserCookieAccessGate.withExplicitRetry {
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                    }
                }
            }
        }
        #expect(keychain.interactiveQueries == 1)
    }

    @Test(arguments: [Browser.chrome, .claudeDesktop])
    func `an actual interactive denial blocks the next manual action`(browser: Browser) {
        let keychain = FakeKeychain(deniesInteraction: true)
        self.withFakeKeychain {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                ProviderInteractionContext.$current.withValue(.userInitiated) {
                    BrowserCookieAccessGate.withExplicitRetry {
                        _ = try? Self.readKey(for: browser, keychain: keychain)
                    }
                    #expect(BrowserCookieAccessGate.hasActiveDenial(for: browser))
                    BrowserCookieAccessGate.withExplicitRetry {
                        #expect(!BrowserCookieAccessGate.shouldAttempt(browser))
                        #expect(!BrowserCookieAccessGate.shouldAttempt(.brave))
                        _ = try? Self.readKey(for: browser, keychain: keychain)
                    }
                }
            }
        }
        #expect(keychain.interactiveQueries == 1)
    }

    @Test
    func `spent allowance still permits cached reads with interaction required metadata`() throws {
        let keychain = FakeKeychain()
        try self.withFakeKeychain {
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                .interactionRequired
            } operation: {
                try ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try BrowserCookieAccessGate.withExplicitRetry {
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                        #expect(BrowserCookieAccessGate.shouldAttempt(.chrome))
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                    }
                }
            }
        }
        #expect(keychain.interactiveQueries == 1)
    }

    @Test
    func `acknowledged no UI recovery clears the browser denial`() throws {
        let keychain = FakeKeychain(promptFreeBrowser: .chrome)
        try self.withFakeKeychain {
            BrowserCookieAccessGate.recordDenied(for: .chrome)
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                try ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try BrowserCookieAccessGate.withExplicitRetry(bypassingCooldown: true) {
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                        BrowserCookieAccessGate.recordAllowed(for: .chrome)
                    }
                    #expect(!BrowserCookieAccessGate.hasActiveDenial(for: .chrome))
                    #expect(BrowserCookieAccessGate.shouldAttempt(.chrome))
                }
            }
        }
        #expect(keychain.interactiveQueries == 0)
    }

    @Test
    func `a sibling no UI failure cannot record an interactive denial`() throws {
        try self.withFakeKeychain {
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                try ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try BrowserCookieAccessGate.withExplicitRetry {
                        try BrowserCookieAccessGate.withRecordReadInteractionPolicy {
                            if BrowserCookieKeychainAccessGate.isUserInteractionDisallowed {
                                throw BrowserCookieError.accessDenied(browser: .chrome, details: "Synthetic")
                            }
                            // Another read fails while this action's interactive read is still pending.
                            do {
                                try BrowserCookieAccessGate.withRecordReadInteractionPolicy { () throws in
                                    throw BrowserCookieError.accessDenied(browser: .chrome, details: "Synthetic")
                                }
                            } catch {
                                BrowserCookieAccessGate.recordIfNeeded(error)
                            }
                            #expect(!BrowserCookieAccessGate.hasActiveDenial(for: .chrome))
                        }
                        BrowserCookieAccessGate.recordAllowed(for: .chrome)
                        #expect(!BrowserCookieAccessGate.hasActiveDenial(for: .chrome))
                    }
                }
            }
        }
    }

    @Test
    func `concurrent escaped imports share one atomic allowance`() {
        let keychain = FakeKeychain()
        self.withFakeKeychain {
            let read = ProviderInteractionContext.$current.withValue(.userInitiated) {
                BrowserCookieAccessGate.withExplicitRetry {
                    BrowserCookieAccessGate.operationPreservingAccessContext { (browser: Browser) in
                        try KeychainAccessGate.withTaskOverrideForTesting(false) {
                            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                                .allowed
                            } operation: {
                                try Self.readKey(for: browser, keychain: keychain)
                            }
                        }
                    }
                }
            }
            let browsers: [Browser] = [.chrome, .brave, .arc, .edge]
            DispatchQueue.concurrentPerform(iterations: browsers.count) { index in
                _ = try? read(browsers[index])
            }
        }
        #expect(keychain.interactiveQueries == 1)
    }

    @Test @MainActor
    func `settings observation refresh does not inherit interactive permission`() async throws {
        let settings = testSettingsStore(
            suiteName: "BrowserCookiePromptContractTests-observation",
            userDefaults: InMemoryUserDefaults())
        let claudeMetadata = try #require(ProviderDescriptorRegistry.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: true)
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bars-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = [
            "HOME": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config", isDirectory: true).path,
        ]
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        var observed: [ProviderInteraction] = []
        store._test_providerRefreshOverride = { _ in observed.append(ProviderInteractionContext.current) }
        defer { store._test_providerRefreshOverride = nil }
        await ProviderInteractionContext.$current.withValue(.userInitiated) {
            await store.refreshForSettingsChange()
        }
        #expect(!observed.isEmpty)
        #expect(observed.allSatisfy { $0 == .background })
    }

    @Test @MainActor
    func `queued settings refresh cannot be promoted by a manual refresh`() {
        var automatic = UsageStore.RequiredRefreshRequest(
            throughGeneration: 1, coalesceProviderRefreshes: false, interaction: .background)
        var manual = UsageStore.RequiredRefreshRequest(
            throughGeneration: 2, coalesceProviderRefreshes: true, interaction: .userInitiated)
        automatic.merge(manual)
        manual.merge(automatic)
        #expect(automatic.interaction == .background)
        #expect(manual.interaction == .background)
    }

    @Test
    func `manual retry respects a recent browser denial`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        let now = Date()
        BrowserCookieAccessGate.recordDenied(for: .brave, now: now)
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            KeychainAccessPreflight
                .withCheckGenericPasswordOverrideForTesting { _, _ in .interactionRequired } operation: {
                    BrowserCookieAccessGate.withExplicitRetry {
                        ProviderInteractionContext.$current.withValue(.userInitiated) {
                            #expect(!BrowserCookieAccessGate.shouldAttempt(.brave, now: now.addingTimeInterval(1)))
                        }
                    }
                }
        }
    }
}
