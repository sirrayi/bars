import Foundation
import Testing
@testable import BarsCLI
@testable import BarsCore

struct TokenAccountCLISelectionTests {
    @Test
    func `Claude credential refresh preserves its local cost directory`() throws {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Personal",
            token: "fixture-old",
            addedAt: 1,
            lastUsed: nil,
            claudeConfigDirectory: "/fixtures/claude-personal")
        let config = BarsConfig(providers: [ProviderConfig(
            id: UsageProvider.claude.instanceID,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0))])
        let store = try Self.configStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(config)
        #expect(try TokenAccountCLIContext.updateStoredTokenAccount(
            store: store,
            provider: .claude,
            accountID: account.id,
            expectedToken: "fixture-old",
            token: "fixture-new"))
        let saved = try #require(try store.load()?.providerConfig(for: .claude)?.tokenAccounts?.accounts.first)
        #expect(saved.token == "fixture-new")
        #expect(saved.claudeConfigDirectory == account.claudeConfigDirectory)
    }

    @Test
    func `other providers retain saved account overrides with CLI source`() throws {
        for selection in Self.accountOverrides {
            let context = try Self.context(provider: .claude, source: .cli, selection: selection)
            #expect(try context.resolvedAccounts(for: .claude).map(\.label) == ["Primary"])
        }
    }

    private static var accountOverrides: [TokenAccountCLISelection] {
        [
            TokenAccountCLISelection(label: "Primary", index: nil, allAccounts: false),
            TokenAccountCLISelection(label: nil, index: 0, allAccounts: false),
            TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
        ]
    }

    private static func context(
        provider: UsageProvider,
        source: ProviderSourceMode,
        selection: TokenAccountCLISelection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false))
        throws -> TokenAccountCLIContext
    {
        let account = ProviderTokenAccount(
            id: UUID(), label: "Primary", token: "fixture-token", addedAt: 0, lastUsed: nil)
        let config = BarsConfig(providers: [ProviderConfig(
            id: provider.instanceID,
            source: source,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0))])
        return try TokenAccountCLIContext(
            selection: selection, config: config, verbose: false, baseEnvironment: [:])
    }

    private static func account(id: UUID = UUID(), token: String) -> ProviderTokenAccount {
        ProviderTokenAccount(id: id, label: "Primary", token: token, addedAt: 0, lastUsed: nil)
    }

    private static func configStore() throws -> BarsConfigStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-account-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return BarsConfigStore(fileURL: directory.appendingPathComponent("config.json"))
    }

    private static func writebackContext(
        config: BarsConfig,
        store: BarsConfigStore) throws -> TokenAccountCLIContext
    {
        try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            configStore: store)
    }

    private static func expectCLIAccountConflict(_ resolve: () throws -> [ProviderTokenAccount]) {
        do {
            _ = try resolve()
            Issue.record("Antigravity CLI must reject saved OAuth account overrides")
        } catch {
            #expect(error.localizedDescription ==
                "Antigravity CLI uses its local login and cannot select saved Google accounts. " +
                "Use --source auto or --source oauth with account selection.")
        }
    }
}
