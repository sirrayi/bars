import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Test
func `ProviderTokenAccountData encoding`() throws {
    let now = Date().timeIntervalSince1970
    let account = ProviderTokenAccount(
        id: UUID(),
        label: "user@example.com",
        token: "test-token",
        addedAt: now,
        lastUsed: now)
    let data = ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0)

    let encoder = JSONEncoder()
    let encoded = try encoder.encode(data)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(ProviderTokenAccountData.self, from: encoded)

    #expect(decoded.version == 1)
    #expect(decoded.accounts.count == 1)
    #expect(decoded.accounts[0].label == "user@example.com")
    #expect(decoded.activeIndex == 0)
}
