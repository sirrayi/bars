import BarsCore
import Foundation
import Testing
@testable import Bars
@testable import BarsCLI

@Suite(.serialized)
@MainActor
struct TokenAccountEnvironmentPrecedenceTests {
    @Test
    func `deepseek token account injects environment in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-deepseek-app")
        settings.addTokenAccount(provider: .deepseek, label: "Account 1", token: "account-token")

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .deepseek,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[DeepSeekSettingsReader.apiKeyEnvironmentKey] == "account-token")
    }

    @Test
    func `deepseek token account injects environment in CLI environment builder`() throws {
        let config = BarsConfig(providers: [])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Account 1",
            token: "account-token",
            addedAt: Date().timeIntervalSince1970,
            lastUsed: nil)

        let env = tokenContext.environment(base: [:], provider: .deepseek, account: account)

        #expect(env[DeepSeekSettingsReader.apiKeyEnvironmentKey] == "account-token")
    }

    @Test
    func `claude OAuth token account overrides environment in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-claude-app")
        settings.addTokenAccount(provider: .claude, label: "OAuth", token: "Bearer sk-ant-oat-account-token")

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[ClaudeOAuthCredentialsStore.environmentTokenKey] == "sk-ant-oat-account-token")
    }

    @Test
    func `claude session account strips ambient admin api credentials in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-claude-admin-strip-app")
        settings.claudeAdminAPIKey = "sk-ant-admin-config"
        settings.addTokenAccount(provider: .claude, label: "Session", token: "sk-ant-session-token")

        let env = ProviderRegistry.makeEnvironment(
            base: [
                "FOO": "bar",
                ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey: "sk-ant-admin-base",
                ClaudeOAuthCredentialsStore.environmentTokenKey: "sk-ant-oat-base",
            ],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey] == nil)
        #expect(env[ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey] == nil)
        #expect(env[ClaudeOAuthCredentialsStore.environmentTokenKey] == nil)
    }

    @Test
    func `claude session key selection carries organization id in app settings snapshot`() throws {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-claude-org-app")
        settings.addTokenAccount(
            provider: .claude,
            label: "Team",
            token: "sk-ant-session-token",
            organizationID: " org-team ")

        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
        let claudeSettings = try #require(snapshot.claude)

        #expect(claudeSettings.manualCookieHeader == "sessionKey=sk-ant-session-token")
        #expect(claudeSettings.organizationID == "org-team")
    }

    @Test
    func `claude OAuth token selection forces OAuth in CLI settings snapshot`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Primary",
                    token: "Bearer sk-ant-oat-account-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = BarsConfig(
            providers: [
                ProviderConfig(
                    id: .claude,
                    cookieSource: .auto,
                    tokenAccounts: accounts),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .claude).first)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .claude, account: account))
        let claudeSettings = try #require(snapshot.claude)

        #expect(claudeSettings.usageDataSource == .oauth)
        #expect(claudeSettings.cookieSource == .off)
        #expect(claudeSettings.manualCookieHeader == nil)
    }

    @Test
    func `claude OAuth token selection injects environment override in CLI`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Primary",
                    token: "Bearer sk-ant-oat-account-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = BarsConfig(
            providers: [
                ProviderConfig(id: .claude, tokenAccounts: accounts),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .claude).first)

        let env = tokenContext.environment(base: ["FOO": "bar"], provider: .claude, account: account)

        #expect(env["FOO"] == "bar")
        #expect(env[ClaudeOAuthCredentialsStore.environmentTokenKey] == "sk-ant-oat-account-token")
    }

    @Test
    func `claude session account strips ambient admin api credentials in CLI environment builder`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Primary",
                    token: "sk-ant-session-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = BarsConfig(
            providers: [
                ProviderConfig(
                    id: .claude,
                    apiKey: "sk-ant-admin-config",
                    tokenAccounts: accounts),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .claude).first)

        let env = tokenContext.environment(
            base: [
                "FOO": "bar",
                ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey: "sk-ant-admin-base",
                ClaudeOAuthCredentialsStore.environmentTokenKey: "sk-ant-oat-base",
            ],
            provider: .claude,
            account: account)

        #expect(env["FOO"] == "bar")
        #expect(env[ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey] == nil)
        #expect(env[ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey] == nil)
        #expect(env[ClaudeOAuthCredentialsStore.environmentTokenKey] == nil)
    }

    @Test
    func `claude OAuth token selection promotes auto source mode in CLI`() throws {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Primary",
            token: "Bearer sk-ant-oat-account-token",
            addedAt: 0,
            lastUsed: nil)
        let config = BarsConfig(providers: [ProviderConfig(id: .claude)])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false)

        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: .auto,
            provider: .claude,
            account: account)

        #expect(effectiveSourceMode == .oauth)
    }

    @Test
    func `claude OAuth token selection reroutes explicit CLI source to OAuth in CLI`() throws {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Primary",
            token: "Bearer sk-ant-oat-account-token",
            addedAt: 0,
            lastUsed: nil)
        let config = BarsConfig(providers: [ProviderConfig(id: .claude)])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false)

        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: .cli,
            provider: .claude,
            account: account)

        #expect(effectiveSourceMode == .oauth)
    }

    @Test
    func `claude session key selection reroutes explicit CLI source to Web in CLI`() throws {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Primary",
            token: "sk-ant-session-token",
            addedAt: 0,
            lastUsed: nil)
        let config = BarsConfig(providers: [ProviderConfig(id: .claude)])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false)

        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: .cli,
            provider: .claude,
            account: account)

        #expect(effectiveSourceMode == .web)
    }

    @Test
    func `claude all accounts reroutes explicit CLI source per selected credential in CLI`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "OAuth",
                    token: "Bearer sk-ant-oat-account-token",
                    addedAt: 0,
                    lastUsed: nil),
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Session",
                    token: "sk-ant-session-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = BarsConfig(
            providers: [
                ProviderConfig(id: .claude, tokenAccounts: accounts),
            ])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
            config: config,
            verbose: false)

        let resolved = try tokenContext.resolvedAccounts(for: .claude)
        #expect(resolved.map(\.label) == ["OAuth", "Session"])

        let oauth = try #require(resolved.first)
        let oauthSnapshot = try #require(tokenContext.settingsSnapshot(for: .claude, account: oauth)?.claude)
        #expect(tokenContext.effectiveSourceMode(base: .cli, provider: .claude, account: oauth) == .oauth)
        #expect(oauthSnapshot.usageDataSource == .oauth)
        #expect(tokenContext.environment(base: [:], provider: .claude, account: oauth)[
            ClaudeOAuthCredentialsStore.environmentTokenKey,
        ] == "sk-ant-oat-account-token")

        let session = try #require(resolved.dropFirst().first)
        let sessionSnapshot = try #require(tokenContext.settingsSnapshot(for: .claude, account: session)?.claude)
        #expect(tokenContext.effectiveSourceMode(base: .cli, provider: .claude, account: session) == .web)
        #expect(sessionSnapshot.cookieSource == .manual)
        #expect(sessionSnapshot.manualCookieHeader == "sessionKey=sk-ant-session-token")
    }

    @Test
    func `claude ambient explicit CLI source remains CLI in CLI`() throws {
        let config = BarsConfig(providers: [ProviderConfig(id: .claude)])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false)

        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: .cli,
            provider: .claude,
            account: nil)

        #expect(effectiveSourceMode == .cli)
    }

    @Test
    func `claude session key selection stays in manual cookie mode in CLI settings snapshot`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Primary",
                    token: "sk-ant-session-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = BarsConfig(
            providers: [
                ProviderConfig(
                    id: .claude,
                    cookieSource: .auto,
                    tokenAccounts: accounts),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .claude).first)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .claude, account: account))
        let claudeSettings = try #require(snapshot.claude)

        #expect(claudeSettings.usageDataSource == .web)
        #expect(claudeSettings.cookieSource == .manual)
        #expect(claudeSettings.manualCookieHeader == "sessionKey=sk-ant-session-token")
    }

    @Test
    func `claude session key selection carries organization id in CLI settings snapshot`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Team",
                    token: "sk-ant-session-token",
                    addedAt: 0,
                    lastUsed: nil,
                    organizationID: " org-team "),
            ],
            activeIndex: 0)
        let config = BarsConfig(
            providers: [
                ProviderConfig(
                    id: .claude,
                    tokenAccounts: accounts),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .claude).first)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .claude, account: account))
        let claudeSettings = try #require(snapshot.claude)

        #expect(claudeSettings.organizationID == "org-team")
    }

    @Test
    func `claude token account organization id uses organizationId JSON key`() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "label": "Team",
          "token": "sk-ant-session-token",
          "addedAt": 0,
          "lastUsed": null,
          "organizationId": "org-team"
        }
        """
        let account = try JSONDecoder().decode(ProviderTokenAccount.self, from: Data(json.utf8))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any]

        #expect(account.organizationID == "org-team")
        #expect(encoded?["organizationId"] as? String == "org-team")
        #expect(encoded?["organizationID"] == nil)
    }

    @Test
    func `claude config manual cookie uses shared route in CLI settings snapshot`() throws {
        let config = BarsConfig(
            providers: [
                ProviderConfig(
                    id: .claude,
                    cookieHeader: "Cookie: sessionKey=sk-ant-session-token; foo=bar"),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .claude, account: nil))
        let claudeSettings = try #require(snapshot.claude)

        #expect(claudeSettings.usageDataSource == .auto)
        #expect(claudeSettings.cookieSource == .manual)
        #expect(claudeSettings.manualCookieHeader == "sessionKey=sk-ant-session-token; foo=bar")
    }

    @Test
    func `claude config manual cookie does not promote auto source mode in CLI`() throws {
        let config = BarsConfig(
            providers: [
                ProviderConfig(
                    id: .claude,
                    cookieHeader: "Cookie: sessionKey=sk-ant-session-token"),
            ])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false)

        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: .auto,
            provider: .claude,
            account: nil)

        #expect(effectiveSourceMode == .auto)
    }

    fileprivate static func fakeJWT(email: String, plan: String, accountId: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": plan,
                "chatgpt_account_id": accountId,
            ],
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}

extension TokenAccountEnvironmentPrecedenceTests {
    fileprivate static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            claudeCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    fileprivate static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
    }

    fileprivate static func makeSnapshotWithAllFields(provider: UsageProvider) throws -> UsageSnapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = Date(timeIntervalSince1970: 1_700_003_600)
        let identity = ProviderIdentitySnapshot(
            providerID: provider.instanceID,
            accountEmail: nil,
            accountOrganization: "Org",
            loginMethod: "Pro")

        return try UsageSnapshot(
            primary: RateWindow(usedPercent: 21, windowMinutes: 60, resetsAt: reset, resetDescription: "primary"),
            secondary: RateWindow(usedPercent: 42, windowMinutes: 1440, resetsAt: nil, resetDescription: "secondary"),
            tertiary: RateWindow(usedPercent: 7, windowMinutes: nil, resetsAt: nil, resetDescription: "tertiary"),
            providerCost: ProviderCostSnapshot(
                used: 12.5,
                limit: 25,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: reset,
                updatedAt: now),
            details: [ProviderDetailSection(rows: [
                ProviderDetailSection.Row(label: "Remaining", value: "$40.00"),
                ProviderDetailSection.Row(label: "Request quota", value: "7 / 70"),
            ])],
            subscriptionExpiresAt: reset.addingTimeInterval(86400),
            subscriptionRenewsAt: reset.addingTimeInterval(43200),
            updatedAt: now,
            identity: identity)
    }

    fileprivate static func expectSnapshotFieldsPreserved(before: UsageSnapshot, after: UsageSnapshot) {
        #expect(after.primary?.usedPercent == before.primary?.usedPercent)
        #expect(after.secondary?.usedPercent == before.secondary?.usedPercent)
        #expect(after.tertiary?.usedPercent == before.tertiary?.usedPercent)
        #expect(after.providerCost?.used == before.providerCost?.used)
        #expect(after.providerCost?.limit == before.providerCost?.limit)
        #expect(after.providerCost?.currencyCode == before.providerCost?.currencyCode)
        #expect(after.details == before.details)
        #expect(after.subscriptionExpiresAt == before.subscriptionExpiresAt)
        #expect(after.subscriptionRenewsAt == before.subscriptionRenewsAt)
        #expect(after.updatedAt == before.updatedAt)
    }
}
