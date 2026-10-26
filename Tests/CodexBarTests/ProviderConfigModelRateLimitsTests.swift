import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ProviderConfigModelRateLimitsTests {
    @Test
    func `legacy provider-level limits decode as the provider key's limits`() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"""
        {"id":"openai","modelRateLimits":[{"model":"gpt-5","tokensPerMinute":100}],
         "tokenAccounts":{"version":1,"activeIndex":0,"accounts":[{
           "id":"00000000-0000-0000-0000-000000000001","label":"Legacy","token":"synthetic","addedAt":0
         }]}}
        """#.utf8))
        #expect(config.modelRateLimits(for: .provider) == [.init(model: "gpt-5", tokensPerMinute: 100)])
        #expect(config.modelRateLimits(for: .tokenAccount(id)).isEmpty)
        #expect(config.tokenAccounts?.accounts.first?.modelRateLimits == nil)
        #expect(config.modelRateLimits(for: .tokenAccount(UUID())).isEmpty)
    }

    private func account(limits: [ProviderModelRateLimit]) -> ProviderTokenAccount {
        ProviderTokenAccount(
            id: UUID(),
            label: "Synthetic",
            token: "synthetic",
            addedAt: 1,
            lastUsed: 2,
            externalIdentifier: "synthetic-id",
            usageScope: "synthetic-scope",
            organizationID: "synthetic-org",
            workspaceID: "synthetic-workspace",
            seatCreditEntitlement: "100",
            modelRateLimits: limits)
    }

    @Test
    func `loading trims drops invalid counts and uses the last duplicate`() throws {
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"""
        {"id":"openai","modelRateLimits":[
          {"model":" ","tokensPerMinute":10},
          {"model":"zero","tokensPerMinute":0},
          {"model":"negative","tokensPerMinute":-1},
          {"model":" gpt-5 ","tokensPerMinute":100,"requestsPerMinute":5},
          {"model":"gpt-5","tokensPerMinute":200,"requestsPerMinute":0},
          {"model":"gpt-4o","tokensPerMinute":100,"requestsPerMinute":-1}
        ]}
        """#.utf8))
        #expect(config.modelRateLimits == [
            .init(model: "gpt-5", tokensPerMinute: 200), .init(model: "gpt-4o", tokensPerMinute: 100),
        ])
    }

    @Test(arguments: ["40000000", "40,000,000", "40M", "40m", " 40M "])
    func `plain grouped and suffix counts parse`(text: String) {
        #expect(ProviderRateLimitNumber.parse(text) == 40_000_000)
    }

    @Test
    func `decimal suffixes round trip exactly without floating point loss`() {
        #expect(ProviderRateLimitNumber.parse("150k") == 150_000)
        #expect(ProviderRateLimitNumber.parse("1.5M") == 1_500_000)
        #expect(ProviderRateLimitNumber.parse("1.001k") == 1001)
        #expect(ProviderRateLimitNumber.parse(String(Int.max)) == Int.max)
        for value in [1, 1001, 150_000, 1_500_000, 40_000_000, Int.max] {
            #expect(ProviderRateLimitNumber.parse(ProviderRateLimitNumber.format(value)) == value)
        }
        #expect(ProviderRateLimitNumber.format(40_000_000) == "40M")
        #expect(ProviderRateLimitNumber.format(150_000) == "150K")
    }

    @Test(arguments: [
        "",
        "0",
        "-1",
        "+1",
        "1.5",
        "1,50",
        "1,,000",
        "1e3",
        "1.0001k",
        "NaN",
        "∞",
        "4B",
        "9223372036854775808",
        "9999999999999999999999999999999999999999999999999M"
    ])
    func `invalid and overflowing counts are rejected`(text: String) {
        #expect(ProviderRateLimitNumber.parse(text) == nil)
    }
}
