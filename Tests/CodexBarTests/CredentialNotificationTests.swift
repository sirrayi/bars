import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CredentialNotificationTests {
    @Test(arguments: ProviderFetchClassifiedError.Kind.allCases)
    func `classified provider failures are authoritative`(kind: ProviderFetchClassifiedError.Kind) {
        let error = ProviderFetchClassifiedError(kind: kind, message: "token expired, login required")
        #expect(ProviderCredentialFailure.isAuthenticationFailure(error) ==
            (kind == .authenticationExpired || kind == .missingCredential))
    }

    @Test(arguments: [false, true])
    func `ordinary and selected account outcomes share account-specific episodes`(selected: Bool) async {
        let settings = testSettingsStore(
            suiteName: "credential-refresh-\(selected)", tokenAccountStore: InMemoryTokenAccountStore())
        settings.credentialExpiryNotificationsEnabled = true
        settings.statusChecksEnabled = false
        settings.addTokenAccount(provider: .deepseek, label: "First", token: "fixture-first")
        settings.addTokenAccount(provider: .deepseek, label: "Second", token: "fixture-second")
        let store = Self.store(settings)
        let accounts = settings.tokenAccounts(for: .deepseek)
        #expect(accounts.count == 2)
        for index in [0, 1, 0] {
            settings.setActiveTokenAccountIndex(index, for: .deepseek)
            let outcome = ProviderFetchOutcome(
                result: .failure(
                    ProviderFetchClassifiedError(
                        kind: .authenticationExpired,
                        message: "synthetic expired credential")),
                attempts: [])
            if selected {
                await store.applySelectedOutcome(
                    outcome,
                    provider: .deepseek,
                    account: accounts[index],
                    fallbackSnapshot: nil)
            } else {
                store._test_providerFetchOutcomeOverride = { _ in outcome }
                await store.refreshProvider(.deepseek, allowDisabled: true)
            }
        }
        #expect(store.credentialNotificationEpisodes.count == 2)
        #expect(Set(store.credentialNotificationEpisodes.keys.map(\.account)) ==
            Set(accounts.compactMap(UsageStore.warningTokenAccountDiscriminator)))
    }

    @Test(arguments: ["before", "authorization", "submission", "denied", "never"])
    func `shared delivery retires notifications when consent or lifecycle changes`(retireAt: String) async throws {
        var current = retireAt != "before"
        var authorized = 0
        var submitted = 0
        var removed = 0
        try await AppNotifications.deliverIfCurrent(
            authorize: {
                authorized += 1
                if retireAt == "authorization" { current = false }
                return retireAt != "denied"
            },
            submit: {
                submitted += 1
                if retireAt == "submission" { current = false }
            },
            remove: { removed += 1 },
            isCurrent: { current })
        #expect(authorized == (retireAt == "before" ? 0 : 1))
        #expect(submitted == (["submission", "never"].contains(retireAt) ? 1 : 0))
        #expect(removed == (retireAt == "submission" ? 1 : 0))
    }

    @Test
    func `Claude identity gaps and later identity resolution preserve independent episodes`() {
        let settings = testSettingsStore(suiteName: "credential-claude-identity")
        settings.credentialExpiryNotificationsEnabled = true
        let store = Self.store(settings)
        let first = store.claudeCredentialNotificationScope(identity: nil, fingerprint: "first-file")
        let second = store.claudeCredentialNotificationScope(identity: nil, fingerprint: "second-file")
        #expect(first != second)
        let expired = Result<ProviderFetchResult, Error>.failure(ClaudeOAuthFetchError.unauthorized)
        store.handleCredentialOutcome(provider: .claude, account: first, result: expired)
        store.handleCredentialOutcome(provider: .claude, account: second, result: expired)
        #expect(store.credentialNotificationEpisodes.count == 2)
        #expect(store.claudeCredentialNotificationScope(identity: "first-account", fingerprint: "first-file") == first)
        #expect(store.claudeCredentialNotificationScope(identity: "first-account", fingerprint: nil) == first)
        #expect(store
            .claudeCredentialNotificationScope(identity: "first-account", fingerprint: "rotated-file") == first)
        #expect(store.claudeCredentialNotificationScope(identity: nil, fingerprint: "rotated-file") == first)
        let switched = store.claudeCredentialNotificationScope(identity: "second-account", fingerprint: "rotated-file")
        #expect(switched != first)
        store.handleCredentialOutcome(provider: .claude, account: switched, result: .success(Self.result()))
        #expect(store.credentialNotificationEpisodes.count == 2)
        store.handleCredentialOutcome(provider: .claude, account: first, result: .success(Self.result()))
        #expect(store.credentialNotificationEpisodes.count == 1)
    }

    private static func store(_ settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    private static func result(source: String = "oauth", diagnostic: String? = nil) -> ProviderFetchResult {
        ProviderFetchResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            credits: nil,
            dashboard: nil,
            sourceLabel: source,
            strategyID: "fixture",
            strategyKind: .oauth,
            diagnostic: diagnostic)
    }
}
