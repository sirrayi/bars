import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStoreTokenRetryPolicyTests {
    @Test
    func `timed out token scans keep the fetch TTL while fast failures retry early`() {
        #expect(UsageStore.tokenFetchFailureRetryDelay(CostUsageError.timedOut(seconds: 600), ttl: 900) == 900)
        #expect(UsageStore.tokenFetchFailureRetryDelay(CocoaError(.fileReadNoSuchFile), ttl: 900) == nil)
        #expect(UsageStore.tokenFetchFailureRetryDelay(NSError(domain: "test", code: 401), ttl: 900) == nil)
        #expect(UsageStore
            .tokenFetchFailureRetryDelay(NSError(domain: "test", code: 500), ttl: 900) == nil)
        #expect(UsageStore
            .tokenFetchFailureRetryDelay(NSError(domain: "test", code: 403), ttl: 900) == nil)
    }
}
