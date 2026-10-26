import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct ProviderCookieRefreshActionTests {
    @Test
    func `cache backed refresh requires a saved cookie even when another credential succeeds`() async {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let outcome = await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
            await ProviderCookieRefreshAction.refresh(provider: .opencode) { true }
        }
        #expect(outcome == .failed)
    }
}
