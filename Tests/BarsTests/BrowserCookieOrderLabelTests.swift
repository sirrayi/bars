import SweetCookieKit
import Testing
@testable import BarsCore

struct BrowserCookieOrderStatusStringTests {
    #if os(macOS)

    @Test
    func `automatic cookie import includes newly supported chromium browsers`() {
        #expect(Browser.defaultImportOrder.contains(.comet))
        #expect(Browser.defaultImportOrder.contains(.yandex))
    }

    @Test
    func `claude cookie import prefers chrome without dropping fallback browsers`() throws {
        let order = try #require(ProviderDefaults.metadata[.claude]?.browserCookieOrder)

        #expect(order.first == .chrome)
        #expect(order.count == Browser.defaultImportOrder.count + 1)
        #expect(Set(order) == Set(Browser.defaultImportOrder + [.claudeDesktop]))
    }

    @Test
    func `Claude desktop import requires explicit selection and excludes other browsers`() {
        #expect(!ClaudeWebAPIFetcher.cookieImportOrder.contains(.claudeDesktop))
        ClaudeWebSessionKeyImport.$desktopApp.withValue(true) {
            #expect(ClaudeWebAPIFetcher.cookieImportOrder == [.claudeDesktop])
        }
        #expect(ClaudeWebAPIFetcher.cookieImportOrder.first == .chrome)
    }

    @Test
    func `opencode go automatic cookies use full provider browser order`() {
        let order = OpenCodeWebCookieSupport.automaticImportOrder(provider: .opencodego)
        #expect(order == ProviderDefaults.metadata[.opencodego]?.browserCookieOrder)
        #expect(order.contains(.edge))
        #expect(order.contains(.firefox))
    }

    @Test
    func `opencode automatic cookies use the shared browser order`() {
        let order = OpenCodeWebCookieSupport.automaticImportOrder(provider: .opencode)
        #expect(order == ProviderDefaults.metadata[.opencode]?.browserCookieOrder)
        #expect(order == Browser.defaultImportOrder)
    }

    @Test
    func `orders listing firefox also include its release channels`() {
        // Channel-owned profiles share `Firefox/Profiles` but only import through their own
        // `Browser` case, so an order that stops at `.firefox` can never reach them.
        let family: Set<Browser> = [.firefox, .firefoxBeta, .firefoxDeveloperEdition, .firefoxNightly]
        let violators = ProviderDefaults.metadata.compactMap { provider, metadata -> UsageProvider? in
            guard let order = metadata.browserCookieOrder, order.contains(where: family.contains) else { return nil }
            return family.isSubset(of: Set(order)) ? nil : provider
        }
        #expect(violators.isEmpty, "orders missing Firefox release channels: \(violators)")
    }
    #endif
}
