import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite("Provider version detection gating")
@MainActor
struct ProviderVersionDetectionGatingTests {
    @Test
    func `empty enabled set probes nothing`() {
        #expect(UsageStore.versionDetectionImplementations(enabled: []).isEmpty)
    }
}
