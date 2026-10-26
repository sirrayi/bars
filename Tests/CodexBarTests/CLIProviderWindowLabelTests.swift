import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIProviderWindowLabelTests {
    @Test
    func `unknown providers and absent usage do not inherit built in window labels`() {
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))
        #expect(Self.payload(providerID: "fixture-custom-provider", usage: usage).rateWindowLabels == nil)
        #expect(Self.payload(providerID: "deepseek", usage: nil).rateWindowLabels == nil)
    }

    private static func payload(providerID: String, usage: UsageSnapshot?) -> ProviderPayload {
        ProviderPayload(
            providerID: providerID,
            account: nil,
            version: nil,
            source: "fixture",
            status: nil,
            usage: usage,
            credits: nil,
            openaiDashboard: nil,
            error: nil)
    }
}
