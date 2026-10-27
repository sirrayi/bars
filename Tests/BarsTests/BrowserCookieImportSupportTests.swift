import Foundation
import SweetCookieKit
import Testing
@testable import BarsCore

struct BrowserCookieImportSupportTests {
    @Test
    func `usable first session leaves later browsers unread`() throws {
        var visited: [Browser] = []
        let sessions = try BrowserCookieImportSupport.collectSessions(
            from: [.safari, .chrome, .firefox],
            missingError: ImportError.missing,
            logger: { _ in },
            load: { browser in
                visited.append(browser)
                return [browser.rawValue]
            })
        #expect(sessions.first(where: { _ in true }) == "safari")
        #expect(visited == [.safari])
    }

    @Test
    func `rejected first session reads only the next browser`() throws {
        var visited: [Browser] = []
        let sessions = try BrowserCookieImportSupport.collectSessions(
            from: [.safari, .chrome, .firefox],
            missingError: ImportError.missing,
            logger: { _ in },
            load: { browser in
                visited.append(browser)
                return [browser.rawValue]
            })
        #expect(sessions.first(where: { $0 != "safari" }) == "chrome")
        #expect(visited == [.safari, .chrome])
    }

    @Test
    func `background denied Chromium is skipped before a usable browser`() async throws {
        try await BrowserCookieAccessGate.withDeniedBrowsersForTesting([.chrome]) {
            try ProviderInteractionContext.$current.withValue(.background) {
                var visited: [Browser] = []
                let sessions = try BrowserCookieImportSupport.collectSessions(
                    from: [.chrome, .firefox, .safari],
                    missingError: ImportError.missing,
                    logger: { _ in },
                    load: { browser -> [String] in
                        guard BrowserCookieAccessGate.shouldAttempt(browser) else { return [] }
                        visited.append(browser)
                        return [browser.rawValue]
                    })
                #expect(sessions.first(where: { _ in true }) == "firefox")
                #expect(visited == [.firefox])
            }
        }
    }

    @Test
    func `automatic plugin import excludes opt in desktop cookies`() {
        #expect(!BrowserCookieImportSupport.importOrder(for: .claude).contains(.claudeDesktop))
        #expect(!BrowserCookieImportSupport.browserNames(for: .claude).contains("Claude desktop app"))
    }

    @Test
    func `empty session iterators let the plugin classify missing credentials`() throws {
        let sessions: AnySequence<String> = try BrowserCookieImportSupport.collectSessions(
            from: [.chrome],
            missingError: nil,
            logger: { _ in },
            load: { _ in [] })
        #expect(Array(sessions).isEmpty)
    }

    private enum ImportError: Error {
        case missing
        case failed
    }

    @Test
    func `collection preserves browser and session order while continuing after failure`() throws {
        var visited: [Browser] = []
        var messages: [String] = []
        let sessions = try BrowserCookieImportSupport.collectSessions(
            from: [.chrome, .firefox, .safari],
            missingError: ImportError.missing,
            logger: { messages.append($0) },
            load: { browser -> [String] in
                visited.append(browser)
                if browser == .firefox { throw ImportError.failed }
                return ["\(browser.rawValue)-first", "\(browser.rawValue)-second"]
            })
        #expect(Array(sessions) == ["chrome-first", "chrome-second", "safari-first", "safari-second"])
        #expect(visited == [.chrome, .firefox, .safari])
        #expect(messages.count == 1)
        #expect(messages.first?.hasPrefix("Firefox cookie import failed: ") == true)
    }

    @Test
    func `empty or failing sources preserve the providers missing session error`() {
        for browsers: [Browser] in [[], [.chrome], [.chrome, .firefox]] {
            #expect(throws: ImportError.missing) {
                let _: AnySequence<String> = try BrowserCookieImportSupport.collectSessions(
                    from: browsers,
                    missingError: ImportError.missing,
                    logger: { _ in },
                    load: { browser in
                        if browser == .firefox { throw ImportError.failed }
                        return []
                    })
            }
        }
    }

    @Test
    func `HTTP conversion merges stores and omits empty profiles without merging accounts`() throws {
        func source(_ id: String, kind: BrowserCookieStoreKind, value: String?) -> BrowserCookieStoreRecords {
            BrowserCookieStoreRecords(
                store: BrowserCookieStore(
                    browser: .chrome,
                    profile: BrowserProfile(id: id, name: id),
                    kind: kind,
                    label: id + (kind == .network ? " (Network)" : ""),
                    databaseURL: nil),
                records: value.map {
                    [BrowserCookieRecord(
                        domain: "example.test",
                        name: "session",
                        path: "/",
                        value: $0,
                        expires: nil,
                        isSecure: true,
                        isHTTPOnly: true)]
                } ?? [])
        }
        let profiles = BrowserCookieImportSupport.httpCookieProfiles(from: [
            source("Beta", kind: .primary, value: "beta"),
            source("Alpha", kind: .primary, value: "old"),
            source("Alpha", kind: .network, value: "network"),
            source("Empty", kind: .primary, value: nil),
        ], origin: .domainBased)
        #expect(profiles.map(\.label) == ["Alpha", "Beta"])
        #expect(try #require(profiles[0].cookies.first).value == "network")
        #expect(try #require(profiles[1].cookies.first).value == "beta")
        #expect(profiles.allSatisfy { $0.cookies.count == 1 })
    }
}
