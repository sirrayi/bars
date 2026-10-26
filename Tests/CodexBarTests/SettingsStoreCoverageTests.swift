import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreCoverageTests {
    @Test
    func `settings fixtures with the same label keep independent persisted values`() {
        let first = Self.makeSettingsStore(suiteName: #function)
        first.refreshFrequency = .fifteenMinutes

        // A second invocation used to erase the first fixture's persisted domain.
        let second = Self.makeSettingsStore(suiteName: #function)
        second.refreshFrequency = .thirtyMinutes

        #expect(first.userDefaults.string(forKey: "refreshFrequency") == RefreshFrequency.fifteenMinutes.rawValue)
        #expect(second.userDefaults.string(forKey: "refreshFrequency") == RefreshFrequency.thirtyMinutes.rawValue)
        #expect(first.configStore.fileURL != second.configStore.fileURL)

        second.userDefaults.removeObject(forKey: "refreshFrequency")
        #expect(first.userDefaults.string(forKey: "refreshFrequency") == RefreshFrequency.fifteenMinutes.rawValue)
    }

    @Test
    func `disabling selected provider clears menu selection`() throws {
        let settings = Self.makeSettingsStore()
        let metadata = ProviderRegistry.shared.metadata

        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)
        try settings.setProviderEnabled(provider: .claude, metadata: #require(metadata[.claude]), enabled: true)
        settings.selectedMenuProvider = .claude

        try settings.setProviderEnabled(provider: .claude, metadata: #require(metadata[.claude]), enabled: false)

        #expect(settings.selectedMenuProvider == nil)
        #expect(settings.enabledProvidersOrdered(metadataByProvider: metadata) == [.codex])
    }

    @Test
    func `agent sessions default off and persist explicit opt in`() throws {
        let suite = "SettingsStoreCoverageTests-agent-sessions-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configStore = testConfigStore(suiteName: suite)

        let initial = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(initial.agentSessionsEnabled == false)
        #expect(initial.agentSessionLabelStyle == .project)
        #expect(defaults.object(forKey: "agentSessionsEnabled") == nil)
        #expect(defaults.object(forKey: "agentSessionLabelStyle") == nil)

        initial.agentSessionsEnabled = true
        initial.agentSessionLabelStyle = .descriptiveAndProject
        #expect(defaults.object(forKey: "agentSessionsEnabled") as? Bool == true)
        #expect(defaults.string(forKey: "agentSessionLabelStyle") == "descriptiveAndProject")

        let reloaded = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded.agentSessionsEnabled)
        #expect(reloaded.agentSessionLabelStyle == .descriptiveAndProject)
    }

    @Test
    func `background low power mode defaults off persists and drives effective web saver`() throws {
        let suite = "SettingsStoreCoverageTests-background-low-power-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configStore = testConfigStore(suiteName: suite)

        let initial = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(initial.backgroundWorkLowPowerModePreference == .off)
        #expect(initial.backgroundWorkLowPowerModeEnabled == false)
        #expect(defaults.string(forKey: "backgroundWorkLowPowerModePreference") == "off")
        #expect(initial.effectiveOpenAIWebBatterySaverEnabled == false)

        let revision = initial.backgroundWorkSettingsRevision
        initial.backgroundWorkLowPowerModePreference = .on

        #expect(initial.backgroundWorkSettingsRevision == revision + 1)
        #expect(initial.effectiveOpenAIWebBatterySaverEnabled)

        let reloaded = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded.backgroundWorkLowPowerModeEnabled)
        #expect(reloaded.effectiveOpenAIWebBatterySaverEnabled)

        reloaded.backgroundWorkLowPowerModePreference = .off
        reloaded.openAIWebBatterySaverEnabled = true
        #expect(reloaded.effectiveOpenAIWebBatterySaverEnabled)
    }

    @Test
    func `background low power mode migrates legacy enabled flag to on preference`() throws {
        let suite = "SettingsStoreCoverageTests-background-low-power-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "backgroundWorkLowPowerModeEnabled")
        let configStore = testConfigStore(suiteName: suite)

        let migrated = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(migrated.backgroundWorkLowPowerModePreference == .on)
        #expect(defaults.string(forKey: "backgroundWorkLowPowerModePreference") == "on")
    }

    @Test
    func `multi account menu layout persists and bridges legacy show all token accounts`() throws {
        let suite = "SettingsStoreCoverageTests-multi-account-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configStore = testConfigStore(suiteName: suite)

        let initial = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(initial.multiAccountMenuLayout == .segmented)

        initial.multiAccountMenuLayout = .stacked
        #expect(defaults.string(forKey: "multiAccountMenuLayout") == MultiAccountMenuLayout.stacked.rawValue)
        #expect(initial.showAllTokenAccountsInMenu)

        let reloaded = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded.multiAccountMenuLayout == .stacked)
        reloaded.showAllTokenAccountsInMenu = false
        #expect(reloaded.multiAccountMenuLayout == .segmented)
    }

    @Test
    func `legacy show all token accounts migrates to stacked layout`() throws {
        let suite = "SettingsStoreCoverageTests-legacy-token-account-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "showAllTokenAccountsInMenu")
        let configStore = testConfigStore(suiteName: suite)

        let settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)

        #expect(settings.multiAccountMenuLayout == .stacked)
    }

    @Test
    func `token account mutations apply side effects`() {
        let settings = Self.makeSettingsStore()

        settings.addTokenAccount(provider: .claude, label: "Primary", token: "token")
        #expect(settings.tokenAccounts(for: .claude).count == 1)
        #expect(settings.claudeCookieSource == .manual)

        let account = settings.selectedTokenAccount(for: .claude)
        #expect(account != nil)

        settings.setActiveTokenAccountIndex(10, for: .claude)
        #expect(settings.selectedTokenAccount(for: .claude)?.id == account?.id)

        if let id = account?.id {
            settings.removeTokenAccount(provider: .claude, accountID: id)
        }
        #expect(settings.tokenAccounts(for: .claude).isEmpty)

        settings.reloadTokenAccounts()
    }

    @Test
    func `claude snapshot uses OAuth routing for OAuth token accounts`() {
        let settings = Self.makeSettingsStore()
        settings.addTokenAccount(provider: .claude, label: "OAuth", token: "Bearer sk-ant-oat-account-token")

        let snapshot = settings.claudeSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.usageDataSource == .oauth)
        #expect(snapshot.cookieSource == .off)
        #expect(snapshot.manualCookieHeader?.isEmpty == true)
    }

    @Test
    func `claude snapshot uses manual cookie routing for session key accounts`() {
        let settings = Self.makeSettingsStore()
        settings.addTokenAccount(provider: .claude, label: "Cookie", token: "sk-ant-session-token")

        let snapshot = settings.claudeSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.usageDataSource == .web)
        #expect(snapshot.cookieSource == .manual)
        #expect(snapshot.manualCookieHeader == "sessionKey=sk-ant-session-token")
    }

    @Test
    func `claude snapshot normalizes config manual cookie input through shared route`() {
        let settings = Self.makeSettingsStore()
        settings.claudeCookieSource = .manual
        settings.claudeCookieHeader = "Cookie: sessionKey=sk-ant-session-token; foo=bar"

        let snapshot = settings.claudeSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.usageDataSource == .auto)
        #expect(snapshot.cookieSource == .manual)
        #expect(snapshot.manualCookieHeader == "sessionKey=sk-ant-session-token; foo=bar")
    }

    @Test
    func `claude snapshot does not fall back to config cookie for malformed selected token account`() {
        let settings = Self.makeSettingsStore()
        settings.claudeCookieSource = .manual
        settings.claudeCookieHeader = "Cookie: sessionKey=sk-ant-config-cookie"
        settings.addTokenAccount(provider: .claude, label: "Malformed", token: "Cookie:")

        let snapshot = settings.claudeSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.cookieSource == .manual)
        #expect(snapshot.manualCookieHeader?.isEmpty == true)
    }

    @Test
    func `opencode go token accounts force manual cookie routing`() {
        let settings = Self.makeSettingsStore()
        settings.addTokenAccount(provider: .opencodego, label: "Go", token: "auth=go-cookie")

        let snapshot = settings.opencodegoSettingsSnapshot(tokenOverride: nil)

        #expect(settings.opencodegoCookieSource == .manual)
        #expect(snapshot.cookieSource == .manual)
        #expect(snapshot.manualCookieHeader == "auth=go-cookie")
    }

    @Test
    func `opencode go snapshot preserves nil workspace id when settings are unset`() {
        let settings = Self.makeSettingsStore()

        let snapshot = settings.opencodegoSettingsSnapshot(tokenOverride: nil)

        #expect(settings.opencodegoWorkspaceID.isEmpty)
        #expect(snapshot.workspaceID == nil)
    }

    @Test
    func `token cost usage source detection`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "token-cost-\(UUID().uuidString)",
            isDirectory: true)
        let codexRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let codexFile = codexRoot.appendingPathComponent("usage.jsonl")
        fileManager.createFile(atPath: codexFile.path, contents: Data("{}".utf8))

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: ["CODEX_HOME": root.path],
            fileManager: fileManager))

        let claudeRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "claude-\(UUID().uuidString)",
            isDirectory: true)
        let claudeProjects = claudeRoot.appendingPathComponent("projects", isDirectory: true)
        try fileManager.createDirectory(at: claudeProjects, withIntermediateDirectories: true)
        let claudeFile = claudeProjects.appendingPathComponent("usage.jsonl")
        fileManager.createFile(atPath: claudeFile.path, contents: Data("{}".utf8))

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: ["CLAUDE_CONFIG_DIR": claudeRoot.path],
            fileManager: fileManager))

        let metadataOnlyHome = fileManager.temporaryDirectory.appendingPathComponent(
            "claude-desktop-metadata-\(UUID().uuidString)",
            isDirectory: true)
        let metadataFile = metadataOnlyHome
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
            .appendingPathComponent("account-id/org-id/local_session.json", isDirectory: false)
        try fileManager.createDirectory(at: metadataFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"cliSessionId":"desktop-cli-session"}"#.utf8).write(to: metadataFile)

        #expect(!SettingsStore.hasAnyTokenCostUsageSources(
            env: [:],
            fileManager: fileManager,
            homeDirectory: metadataOnlyHome))

        let desktopHome = fileManager.temporaryDirectory.appendingPathComponent(
            "claude-desktop-\(UUID().uuidString)",
            isDirectory: true)
        let desktopProjects = desktopHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
            .appendingPathComponent("workspace-id", isDirectory: true)
            .appendingPathComponent("session-id", isDirectory: true)
            .appendingPathComponent("local_agent", isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        try fileManager.createDirectory(at: desktopProjects, withIntermediateDirectories: true)
        let desktopFile = desktopProjects
            .appendingPathComponent("project-a", isDirectory: true)
            .appendingPathComponent("session-a.jsonl", isDirectory: false)
        try fileManager.createDirectory(at: desktopFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: desktopFile.path, contents: Data("{}".utf8))

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: [:],
            fileManager: fileManager,
            homeDirectory: desktopHome))

        let desktopCodeHome = fileManager.temporaryDirectory.appendingPathComponent(
            "claude-desktop-code-\(UUID().uuidString)",
            isDirectory: true)
        let desktopCodeFile = desktopCodeHome
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
            .appendingPathComponent("account-id/org-id/.claude/projects/project-a", isDirectory: true)
            .appendingPathComponent("session-a.jsonl", isDirectory: false)
        try fileManager.createDirectory(
            at: desktopCodeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        fileManager.createFile(atPath: desktopCodeFile.path, contents: Data("{}".utf8))

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: [:],
            fileManager: fileManager,
            homeDirectory: desktopCodeHome))
    }

    @Test
    func `claude keychain prompt mode defaults to only on user action`() {
        let settings = Self.makeSettingsStore()
        #expect(settings.claudeOAuthKeychainPromptMode == .onlyOnUserAction)
    }

    @Test
    func `claude keychain prompt mode persists across store reload`() throws {
        let suite = "SettingsStoreCoverageTests-claude-keychain-prompt-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configStore = testConfigStore(suiteName: suite)

        let first = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        first.claudeOAuthKeychainPromptMode = .never
        #expect(
            defaults.string(forKey: "claudeOAuthKeychainPromptMode")
                == ClaudeOAuthKeychainPromptMode.never.rawValue)

        let second = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(second.claudeOAuthKeychainPromptMode == .never)
    }

    @Test
    func `claude keychain prompt mode invalid raw falls back to only on user action`() throws {
        let suite = "SettingsStoreCoverageTests-claude-keychain-prompt-mode-invalid-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid-mode", forKey: "claudeOAuthKeychainPromptMode")
        let configStore = testConfigStore(suiteName: suite)

        let settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(settings.claudeOAuthKeychainPromptMode == .onlyOnUserAction)
    }

    @Test
    func `claude keychain read strategy defaults to security framework`() {
        let settings = Self.makeSettingsStore()
        #expect(settings.claudeOAuthKeychainReadStrategy == .securityFramework)
    }

    @Test
    func `claude keychain read strategy persists across store reload`() throws {
        let suite = "SettingsStoreCoverageTests-claude-keychain-read-strategy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configStore = testConfigStore(suiteName: suite)

        let first = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        first.claudeOAuthKeychainReadStrategy = .securityFramework
        #expect(
            defaults.string(forKey: "claudeOAuthKeychainReadStrategy")
                == ClaudeOAuthKeychainReadStrategy.securityFramework.rawValue)

        let second = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(second.claudeOAuthKeychainReadStrategy == .securityFramework)
    }

    @Test
    func `claude legacy security CLI read strategy preserves no prompt intent`() throws {
        let suite = "SettingsStoreCoverageTests-claude-keychain-read-strategy-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ClaudeOAuthKeychainReadStrategy.securityCLIExperimental.rawValue,
            forKey: "claudeOAuthKeychainReadStrategy")
        let configStore = testConfigStore(suiteName: suite)

        let settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)

        #expect(settings.claudeOAuthKeychainReadStrategy == .securityFramework)
        #expect(settings.claudeOAuthKeychainPromptMode == .never)
        #expect(settings.claudeOAuthPromptFreeCredentialsEnabled)
        #expect(
            defaults.string(forKey: "claudeOAuthKeychainReadStrategy")
                == ClaudeOAuthKeychainReadStrategy.securityFramework.rawValue)
        #expect(
            defaults.string(forKey: "claudeOAuthKeychainPromptMode")
                == ClaudeOAuthKeychainPromptMode.never.rawValue)
    }

    @Test
    func `claude legacy security CLI migration preserves explicit prompt policy`() throws {
        let suite = "SettingsStoreCoverageTests-claude-keychain-explicit-prompt-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ClaudeOAuthKeychainReadStrategy.securityCLIExperimental.rawValue,
            forKey: "claudeOAuthKeychainReadStrategy")
        defaults.set(
            ClaudeOAuthKeychainPromptMode.always.rawValue,
            forKey: "claudeOAuthKeychainPromptMode")
        let configStore = testConfigStore(suiteName: suite)

        let settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)

        #expect(settings.claudeOAuthKeychainReadStrategy == .securityFramework)
        #expect(settings.claudeOAuthKeychainPromptMode == .always)
        #expect(!settings.claudeOAuthPromptFreeCredentialsEnabled)
    }

    @Test
    func `claude keychain read strategy invalid raw falls back to security framework`() throws {
        let suite = "SettingsStoreCoverageTests-claude-keychain-read-strategy-invalid-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid-strategy", forKey: "claudeOAuthKeychainReadStrategy")
        let configStore = testConfigStore(suiteName: suite)

        let settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(settings.claudeOAuthKeychainReadStrategy == .securityFramework)
    }

    @Test
    func `claude prompt free credentials toggle maps to never prompt policy`() {
        let settings = Self.makeSettingsStore()
        #expect(settings.claudeOAuthPromptFreeCredentialsEnabled == false)

        settings.claudeOAuthPromptFreeCredentialsEnabled = true
        #expect(settings.claudeOAuthKeychainReadStrategy == .securityFramework)
        #expect(settings.claudeOAuthKeychainPromptMode == .never)

        settings.claudeOAuthPromptFreeCredentialsEnabled = false
        #expect(settings.claudeOAuthKeychainReadStrategy == .securityFramework)
        #expect(settings.claudeOAuthKeychainPromptMode == .onlyOnUserAction)
    }

    @Test
    func `weekly progress work days defaults to nil and persists across store reload`() throws {
        let suite = "SettingsStoreCoverageTests-weekly-progress-work-days-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configStore = testConfigStore(suiteName: suite)

        let fresh = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(fresh.weeklyProgressWorkDays == nil)

        fresh.weeklyProgressWorkDays = 5
        #expect(defaults.object(forKey: "weeklyProgressWorkDays") as? Int == 5)

        let reloaded = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded.weeklyProgressWorkDays == 5)

        fresh.weeklyProgressWorkDays = 4
        #expect(reloaded.weeklyProgressWorkDays == 5)

        let reloaded2 = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded2.weeklyProgressWorkDays == 4)

        reloaded2.weeklyProgressWorkDays = 7
        let reloaded3 = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded3.weeklyProgressWorkDays == 7)

        reloaded3.weeklyProgressWorkDays = nil
        #expect(defaults.object(forKey: "weeklyProgressWorkDays") == nil)
        let reloaded4 = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded4.weeklyProgressWorkDays == nil)
    }

    @Test
    func `workday tick appearance defaults to subtle and persists valid choices`() throws {
        let suite = "SettingsStoreCoverageTests-workday-tick-appearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configStore = testConfigStore(suiteName: suite)

        let fresh = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(fresh.workdayTickAppearance == .subtle)

        fresh.workdayTickAppearance = .highContrast
        #expect(defaults.string(forKey: "workdayTickAppearance") == WorkdayTickAppearance.highContrast.rawValue)

        let reloaded = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded.workdayTickAppearance == .highContrast)

        defaults.set("unknown", forKey: "workdayTickAppearance")
        let invalid = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(invalid.workdayTickAppearance == .subtle)
    }

    @Test
    func `preferred currency defaults to USD and persists an explicit selection`() {
        let suite = "SettingsStoreCoverageTests-preferred-currency-\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults()
        let configStore = testConfigStore(suiteName: suite)

        let fresh = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(fresh.preferredCurrencyCode == "USD")

        fresh.preferredCurrencyCode = "GBP"
        let reloaded = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded.preferredCurrencyCode == "GBP")

        reloaded.preferredCurrencyCode = "AED"
        let reloadedAED = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloadedAED.preferredCurrencyCode == "AED")

        for code in ["NZD", "SEK", "NOK", "DKK", "PLN", "BRL", "MXN", "ZAR", "THB", "IDR", "VND", "UAH", "ILS"] {
            reloadedAED.preferredCurrencyCode = code
            let reloadedCurrency = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
            #expect(reloadedCurrency.preferredCurrencyCode == code)
        }
    }

    @Test
    func `preferred currency picker matches every supported exchange currency`() {
        let codes = PreferredCurrencyOption.codes
        #expect(codes.first == "auto")
        #expect(Array(codes.dropFirst()) == CurrencyExchange.supportedCurrencies)
        #expect(Set(codes).count == codes.count)
        #expect(codes.dropFirst().map { PreferredCurrencyOption.label(for: $0) } == [
            "USD ($)", "GBP (£)", "EUR (€)", "CZK (Kč)", "CNY (¥)", "JPY (¥)", "KRW (₩)", "CAD ($)",
            "AUD ($)", "HKD ($)", "TWD (NT$)", "SGD ($)", "INR (₹)", "CHF (Fr.)", "AED (د.إ)", "TRY (₺)",
            "NZD ($)", "SEK (kr)", "NOK (kr)", "DKK (kr)", "PLN (zł)", "BRL (R$)", "MXN ($)", "ZAR (R)",
            "THB (฿)", "IDR (Rp)", "VND (₫)", "UAH (₴)", "ILS (₪)",
        ])
        #expect(PreferredCurrencyOption.label(for: "auto") == L("currency_auto"))
        #expect(PreferredCurrencyOption.label(for: "XYZ") == "XYZ")
    }

    private static func makeSettingsStore(
        suiteName: String = "SettingsStoreCoverageTests")
        -> SettingsStore
    {
        let defaults = InMemoryUserDefaults()
        defaults.set(false, forKey: "debugDisableKeychainAccess")
        let configStore = testConfigStore(suiteName: "\(suiteName)-\(UUID().uuidString)")
        return Self.makeSettingsStore(
            userDefaults: defaults,
            configStore: configStore)
    }

    private static func makeSettingsStore(
        userDefaults: UserDefaults,
        configStore: CodexBarConfigStore)
        -> SettingsStore
    {
        SettingsStore(
            userDefaults: userDefaults,
            configStore: configStore,
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
