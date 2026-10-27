import BarsCore
import Foundation
import Testing
@testable import Bars

@Suite("Provider version detection gating")
@MainActor
struct ProviderVersionDetectionGatingTests {
    @Test
    func `empty enabled set probes nothing`() {
        #expect(UsageStore.versionDetectionImplementations(enabled: []).isEmpty)
    }
}
