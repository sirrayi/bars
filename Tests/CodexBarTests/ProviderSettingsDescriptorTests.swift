import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct ProviderSettingsDescriptorTests {
    @Test
    func `OpenCode Go can add API accounts while automatic cookies are selected`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-opencodego-accounts")
        fixture.settings.opencodegoCookieSource = .auto
        let support = try #require(TokenAccountSupportCatalog.support(for: .opencodego))
        #expect(OpenCodeGoProviderImplementation().tokenAccountsVisibility(
            context: fixture.settingsContext(provider: .opencodego), support: support))
        #expect(support.subtitle.contains("API keys"))
    }

    @Test
    func `provider settings refresh enables explicit browser retry`() async {
        var observedInteraction: ProviderInteraction?
        var browserRetryAllowed = false

        await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await BrowserCookieAccessGate.withDeniedBrowsersForTesting([.chrome]) {
                await ProviderSettingsRefreshInteraction.perform {
                    observedInteraction = ProviderInteractionContext.current
                    browserRetryAllowed = BrowserCookieAccessGate.shouldAttempt(.chrome)
                }
            }
        }

        #expect(observedInteraction == .userInitiated)
        #expect(browserRetryAllowed)
    }

    @Test
    func `toggle I ds are unique across providers`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-unique")
        var seenToggleIDs: Set<String> = []
        var seenActionIDs: Set<String> = []
        var seenPickerIDs: Set<String> = []
        var seenSettingsActionGroupIDs: Set<String> = []

        for provider in UsageProvider.allCases {
            let context = fixture.settingsContext(provider: provider)
            let impl = try #require(ProviderCatalog.implementation(for: provider))
            let toggles = impl.settingsToggles(context: context)
            for toggle in toggles {
                #expect(!seenToggleIDs.contains(toggle.id))
                seenToggleIDs.insert(toggle.id)

                for action in toggle.actions {
                    #expect(!seenActionIDs.contains(action.id))
                    seenActionIDs.insert(action.id)
                }
            }

            let pickers = impl.settingsPickers(context: context)
            for picker in pickers {
                #expect(!seenPickerIDs.contains(picker.id))
                seenPickerIDs.insert(picker.id)
            }

            let actionGroups = impl.settingsActions(context: context)
            for actionGroup in actionGroups {
                #expect(!seenSettingsActionGroupIDs.contains(actionGroup.id))
                seenSettingsActionGroupIDs.insert(actionGroup.id)

                for action in actionGroup.actions {
                    #expect(!seenActionIDs.contains(action.id))
                    seenActionIDs.insert(action.id)
                }
            }
        }
    }

    @Test
    func `open code cookie refresh commits replacement through user initiated gate`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-opencode-refresh")
        let context = fixture.settingsContext(provider: .opencode)
        let picker = try #require(OpenCodeProviderImplementation().settingsPickers(context: context).first)
        let action = try #require(picker.trailingActions.first)
        let service = "com.steipete.codexbar.tests.settings-cookie-refresh.\(UUID().uuidString)"
        var observedInteraction: ProviderInteraction?

        #expect(action.title == "Refresh")
        #expect(action.isVisible?() == true)

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: .opencode,
                    cookieHeader: "old-test-cookie",
                    sourceLabel: "Test old")
                fixture.store._test_providerRefreshOverride = { provider in
                    observedInteraction = ProviderInteractionContext.current
                    CookieHeaderCache.store(
                        provider: provider,
                        cookieHeader: "new-test-cookie",
                        sourceLabel: "Test new")
                    fixture.store.snapshots[provider.instanceID] = UsageSnapshot(
                        primary: nil,
                        secondary: nil,
                        updatedAt: Date())
                    fixture.store.lastSourceLabels[provider.instanceID] = "web"
                }
                defer { fixture.store._test_providerRefreshOverride = nil }

                await action.perform()

                #expect(observedInteraction == .userInitiated)
                #expect(CookieHeaderCache.load(provider: .opencode)?.cookieHeader == "new-test-cookie")
                #expect(picker.trailingText?()?.contains("Test new") == true)
            }
        }
    }

    @Test
    func `open code go cookie refresh rejects local fallback cookie`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-opencodego-validation")
        let context = fixture.settingsContext(provider: .opencodego)
        let picker = try #require(OpenCodeGoProviderImplementation().settingsPickers(context: context).first)
        let action = try #require(picker.trailingActions.first)
        let service = "com.steipete.codexbar.tests.settings-cookie-validation.\(UUID().uuidString)"

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: .opencodego,
                    cookieHeader: "old-test-cookie",
                    sourceLabel: "Test old")
                fixture.store._test_providerRefreshOverride = { provider in
                    CookieHeaderCache.store(
                        provider: provider,
                        cookieHeader: "invalid-test-cookie",
                        sourceLabel: "Test invalid")
                    fixture.store.snapshots[provider.instanceID] = UsageSnapshot(
                        primary: nil,
                        secondary: nil,
                        updatedAt: Date())
                    fixture.store.lastSourceLabels[provider.instanceID] = "local"
                }
                defer { fixture.store._test_providerRefreshOverride = nil }

                await action.perform()

                #expect(CookieHeaderCache.load(provider: .opencodego)?.cookieHeader == "old-test-cookie")
                #expect(picker.trailingText?() == L("Failed"))
            }
        }
    }

    @Test
    func `open code cookie refresh rejects missing validation snapshot`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-opencode-validation")
        let context = fixture.settingsContext(provider: .opencode)
        let picker = try #require(OpenCodeProviderImplementation().settingsPickers(context: context).first)
        let action = try #require(picker.trailingActions.first)
        let service = "com.steipete.codexbar.tests.settings-cookie-missing-snapshot.\(UUID().uuidString)"
        fixture.store.snapshots[.opencode] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date())
        fixture.store.lastSourceLabels[.opencode] = "web"

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: .opencode,
                    cookieHeader: "old-test-cookie",
                    sourceLabel: "Test old")
                fixture.store._test_providerRefreshOverride = { provider in
                    CookieHeaderCache.store(
                        provider: provider,
                        cookieHeader: "unvalidated-test-cookie",
                        sourceLabel: "Test unvalidated")
                    fixture.store.snapshots.removeValue(forKey: provider.instanceID)
                }
                defer { fixture.store._test_providerRefreshOverride = nil }

                await action.perform()

                #expect(CookieHeaderCache.load(provider: .opencode)?.cookieHeader == "old-test-cookie")
                #expect(picker.trailingText?() == L("Failed"))
            }
        }
    }

    @Test
    func `open code cookie refresh respects denial cooldown and preserves unvalidated cookie`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-opencode-cooldown")
        let context = fixture.settingsContext(provider: .opencode)
        let picker = try #require(OpenCodeProviderImplementation().settingsPickers(context: context).first)
        let action = try #require(picker.trailingActions.first)
        let service = "com.steipete.codexbar.tests.settings-cookie-cooldown.\(UUID().uuidString)"
        var explicitRetryAllowed = false

        BrowserCookieAccessGate.resetForTesting()
        BrowserCookieAccessGate.recordDenied(for: .chrome)
        defer { BrowserCookieAccessGate.resetForTesting() }

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: .opencode,
                    cookieHeader: "old-test-cookie",
                    sourceLabel: "Test old")
                fixture.store._test_providerRefreshOverride = { _ in
                    explicitRetryAllowed = KeychainAccessGate.withTaskOverrideForTesting(false) {
                        BrowserCookieAccessGate.shouldAttempt(.chrome)
                    }
                }
                defer { fixture.store._test_providerRefreshOverride = nil }

                await action.perform()

                #expect(!explicitRetryAllowed)
                #expect(CookieHeaderCache.load(provider: .opencode)?.cookieHeader == "old-test-cookie")
                #expect(picker.trailingText?() == L("Failed"))
            }
        }
    }

    private func captureAntigravitySourcePicker(
        _ picker: ProviderSettingsPickerDescriptor,
        directory: String) throws
    {
        let environment = ProcessInfo.processInfo.environment
        precondition(environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1")
        precondition(environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1")
        precondition(environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1")
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let view = NSHostingView(rootView:
            Form {
                Section("Antigravity · synthetic settings") {
                    ProviderSettingsPickerRowView(picker: picker)
                }
            }.formStyle(.grouped).frame(width: 740, height: 210))
        view.frame = NSRect(x: 0, y: 0, width: 740, height: 210)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("source-picker.png"))
        try picker.subtitle.write(
            to: output.appendingPathComponent("source-picker.txt"), atomically: true, encoding: .utf8)
    }

    @Test
    func `claude exposes usage and cookie pickers`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude")
        fixture.settings.debugDisableKeychainAccess = false
        let context = fixture.settingsContext(provider: .claude)

        let pickers = ClaudeProviderImplementation().settingsPickers(context: context)
        let usagePicker = try #require(pickers.first(where: { $0.id == "claude-usage-source" }))
        #expect(usagePicker.placement == .connection)
        #expect(pickers.contains(where: { $0.id == "claude-cookie-source" }))
        let toggles = ClaudeProviderImplementation().settingsToggles(context: context)
        #expect(!toggles.contains(where: { $0.id == "claude-peak-hours" }))
        let keychainPicker = try #require(pickers.first(where: { $0.id == "claude-keychain-prompt-policy" }))
        let optionIDs = Set(keychainPicker.options.map(\.id))
        #expect(optionIDs.contains(ClaudeOAuthKeychainPromptMode.never.rawValue))
        #expect(optionIDs.contains(ClaudeOAuthKeychainPromptMode.onlyOnUserAction.rawValue))
        #expect(optionIDs.contains(ClaudeOAuthKeychainPromptMode.always.rawValue))
        #expect(keychainPicker.isEnabled?() ?? true)
    }

    @Test
    func `provider implementations omit superseded one-off usage visibility toggles`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-shared-usage-items")
        let claudeContext = fixture.settingsContext(provider: .claude)

        #expect(!ClaudeProviderImplementation().settingsToggles(context: claudeContext).contains {
            $0.id == "claude-daily-routines-usage-visible"
        })
    }

    @Test
    func `claude model scoped widget usage toggle is default off and independent`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-model-scoped-widget")
        let context = fixture.settingsContext(provider: .claude)
        let toggles = ClaudeProviderImplementation().settingsToggles(context: context)
        let widgetToggle = try #require(toggles.first {
            $0.id == "claude-model-scoped-weekly-usage-visible"
        })

        #expect(widgetToggle.binding.wrappedValue == false)
        #expect(widgetToggle.isEnabled == nil)
        #expect(widgetToggle.subtitle.contains("Fable"))

        widgetToggle.binding.wrappedValue = true
        #expect(fixture.settings.claudeModelScopedWeeklyUsageVisible)

        fixture.settings.showOptionalCreditsAndExtraUsage = false
        #expect(widgetToggle.isEnabled == nil)
    }

    @Test
    func `claude single swap account toggle persists and follows integration visibility`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-swap-single")
        let context = fixture.settingsContext(provider: .claude)
        let toggles = ClaudeProviderImplementation().settingsToggles(context: context)
        let singleAccountToggle = try #require(toggles.first {
            $0.id == "claude-swap-show-single-account"
        })

        #expect(singleAccountToggle.binding.wrappedValue == false)
        #expect(singleAccountToggle.isVisible?() == false)

        fixture.settings.claudeSwapEnabled = true
        #expect(singleAccountToggle.isVisible?() == true)
        singleAccountToggle.binding.wrappedValue = true

        #expect(fixture.settings.claudeSwapShowSingleAccount)
        #expect(fixture.settings.configSnapshot.providerConfig(for: .claude)?.claudeSwapShowSingleAccount == true)
    }

    @Test
    func `claude prompt policy picker remains visible for prompt free toggle`() throws {
        let fixture = try self.makeSettingsFixture(
            suite: "ProviderSettingsDescriptorTests-claude-prompt-visible-prompt-free")
        fixture.settings.debugDisableKeychainAccess = false
        fixture.settings.claudeOAuthPromptFreeCredentialsEnabled = true
        let context = fixture.settingsContext(provider: .claude)

        let pickers = ClaudeProviderImplementation().settingsPickers(context: context)
        let keychainPicker = try #require(pickers.first(where: { $0.id == "claude-keychain-prompt-policy" }))
        #expect(keychainPicker.isVisible?() ?? true)
        #expect(keychainPicker.binding.wrappedValue == ClaudeOAuthKeychainPromptMode.never.rawValue)
    }

    @Test
    func `claude avoid keychain prompts toggle is disabled when global keychain disabled`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-prompt-free-disabled")
        fixture.settings.debugDisableKeychainAccess = true
        fixture.settings.claudeOAuthPromptFreeCredentialsEnabled = true
        let context = fixture.settingsContext(provider: .claude)

        let toggles = ClaudeProviderImplementation().settingsToggles(context: context)
        let promptFreeToggle = try #require(toggles.first(where: { $0.id == "claude-oauth-prompt-free-credentials" }))
        #expect(promptFreeToggle.isEnabled?() == false)
        #expect(promptFreeToggle.binding.wrappedValue == true)

        promptFreeToggle.binding.wrappedValue = false
        #expect(fixture.settings.claudeOAuthPromptFreeCredentialsEnabled == true)

        fixture.settings.debugDisableKeychainAccess = false
        #expect(promptFreeToggle.isEnabled?() == true)
        #expect(promptFreeToggle.binding.wrappedValue == true)
    }

    @Test
    func `claude keychain prompt policy picker disabled when global keychain disabled`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-keychain-disabled")
        fixture.settings.debugDisableKeychainAccess = true
        let context = fixture.settingsContext(provider: .claude)

        let pickers = ClaudeProviderImplementation().settingsPickers(context: context)
        let keychainPicker = try #require(pickers.first(where: { $0.id == "claude-keychain-prompt-policy" }))
        #expect(keychainPicker.isEnabled?() == false)
        let subtitle = keychainPicker.dynamicSubtitle?() ?? ""
        #expect(subtitle.localizedCaseInsensitiveContains("inactive"))
    }

    @Test
    func `claude web extras auto disables when leaving CLI`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-invariant")
        let settings = fixture.settings
        settings.debugMenuEnabled = true
        settings.claudeUsageDataSource = .cli
        settings.claudeWebExtrasEnabled = true

        settings.claudeUsageDataSource = .oauth
        #expect(settings.claudeWebExtrasEnabled == false)
    }
}

extension ProviderSettingsDescriptorTests {
    @Test
    func `devin presentation follows store source label`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-devin-presentation")
        fixture.store.lastSourceLabels[.devin] = "web"
        let metadata = try #require(ProviderDescriptorRegistry.metadata[.devin])
        let context = fixture.presentationContext(provider: .devin, metadata: metadata)

        let detailLine = DevinProviderImplementation()
            .presentation(context: context)
            .detailLine(context)

        #expect(detailLine == "web")
    }

    @Test
    func `devin automatic auth explains Chromium browser support`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-devin-browsers")
        fixture.settings.devinCookieSource = .auto
        let picker = try #require(DevinProviderImplementation()
            .settingsPickers(context: fixture.settingsContext(provider: .devin)).first)

        #expect(picker.subtitle == "Automatically imports the app.devin.ai session from Chromium browsers.")
    }
}

extension ProviderSettingsDescriptorTests {
    @Test
    func `deepseek profile picker contains only validated profiles and persists selection`() throws {
        let apiKey = "test-deepseek-api-key"
        let fixture = try self.makeSettingsFixture(
            suite: "ProviderSettingsDescriptorTests-deepseek-profiles",
            environmentBase: [DeepSeekSettingsReader.apiKeyEnvironmentKey: apiKey])
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())
        let context = fixture.settingsContext(provider: .deepseek)

        let picker = try #require(DeepSeekProviderImplementation().settingsPickers(context: context).first)
        #expect(picker.options.map(\.id) == ["", "chrome:Default", "chrome:Profile 2"])
        #expect(picker.binding.wrappedValue.isEmpty)
        let configRevision = fixture.settings.configRevision
        let backgroundWorkRevision = fixture.settings.backgroundWorkSettingsRevision
        let providerConfigRevision = fixture.settings.providerConfigRevision(for: .deepseek)
        let snapshot = fixture.store.snapshots[.deepseek]

        picker.binding.wrappedValue = "chrome:Profile 2"
        #expect(fixture.settings.deepseekProfileID(apiKey: apiKey) == "chrome:Profile 2")
        #expect(fixture.settings.providerConfig(for: .deepseek)?.sanitizedDeepSeekProfileID == "chrome:Profile 2")
        let expectedScope = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: nil,
            apiKey: apiKey))
        #expect(fixture.settings.providerConfig(for: .deepseek)?.sanitizedDeepSeekProfileScope == expectedScope)
        #expect(fixture.settings.configRevision == configRevision)
        #expect(fixture.settings.backgroundWorkSettingsRevision == backgroundWorkRevision)
        #expect(fixture.settings.providerConfigRevision(for: .deepseek) == providerConfigRevision + 1)
        #expect(fixture.store.snapshots[.deepseek]?.updatedAt == snapshot?.updatedAt)
        #expect(fixture.store.snapshots[.deepseek]?.deepseekPlatformProfiles.map(\.id) == [
            "chrome:Default",
            "chrome:Profile 2",
        ])
    }

    @Test
    func `deepseek browser only profile selection persists without an API key`() async throws {
        let fixture = try self.makeSettingsFixture(
            suite: "ProviderSettingsDescriptorTests-deepseek-browser-only-profile")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06 (Paid: $8.06 / Granted: $0.00)"),
            secondary: nil,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())

        let picker = try #require(DeepSeekProviderImplementation()
            .settingsPickers(context: fixture.settingsContext(provider: .deepseek)).first)
        picker.binding.wrappedValue = "chrome:Profile 2"

        #expect(fixture.settings.deepseekProfileID(apiKey: nil) == "chrome:Profile 2")
        #expect(fixture.settings.providerConfig(for: .deepseek)?.sanitizedDeepSeekProfileScope != nil)
        #expect(fixture.store.deepseekProfileTransitionSnapshot?.primary?.resetDescription == "Refreshing")

        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(
                result: .failure(DeepSeekUsageError.networkError("offline")),
                attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)

        #expect(fixture.store.deepseekProfileTransitionSnapshot?.primary?.resetDescription == "Unavailable")
        #expect(fixture.store.deepseekProfileTransitionSnapshot?.primary?.resetDescription?.contains("$8.06") == false)
    }

    @Test
    func `deepseek profile picker stays visible while switching profiles`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-profile-switch")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())
        fixture.store.lastKnownResetSnapshots[.deepseek] = snapshot
        fixture.store.snapshots.removeValue(forKey: .deepseek)
        fixture.store.refreshingProviders.insert(.deepseek)
        let context = fixture.settingsContext(provider: .deepseek)

        let picker = try #require(DeepSeekProviderImplementation().settingsPickers(context: context).first)
        #expect(picker.options.map(\.id) == ["", "chrome:Default", "chrome:Profile 2"])
        #expect(picker.binding.wrappedValue.isEmpty)
        #expect(picker.dynamicSubtitle?() == "Refreshing")
        #expect(!(picker.isEnabled?() ?? true))
    }

    @Test
    func `deepseek browser profile cancellation does not leave refreshing behind`() async throws {
        let fixture = try self.makeSettingsFixture(
            suite: "ProviderSettingsDescriptorTests-deepseek-browser-cancelled-transition")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06"),
            secondary: nil,
            updatedAt: Date())
        fixture.store.beginDeepSeekProfileTransition(preservingBalance: false)

        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(result: .failure(CancellationError()), attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)

        #expect(fixture.store.deepseekProfileTransitionSnapshot?.primary?.resetDescription == "Unavailable")
    }

    @Test
    func `deepseek settings keeps balance while live snapshot is switching`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-balance-switch")
        fixture.store.lastKnownResetSnapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$9.32 (Paid: $9.32 / Granted: $0.00)"),
            secondary: nil,
            updatedAt: Date())
        fixture.store.snapshots.removeValue(forKey: .deepseek)
        fixture.store.refreshingProviders.insert(.deepseek)

        let model = ProvidersPane(settings: fixture.settings, store: fixture.store)
            ._test_menuCardModel(for: .deepseek)

        let balance = try #require(model.metrics.first)
        #expect(balance.title == "Balance")
        #expect(balance.statusText == "$9.32 (Paid: $9.32 / Granted: $0.00)")
        #expect(model.usageNotes.isEmpty)
        #expect(model.inlineUsageDashboard == nil)
        #expect(model.placeholder == nil)
    }

    @Test
    func `deepseek profile transition survives selected api token cache invalidation`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-token-transition")
        fixture.settings.addTokenAccount(provider: .deepseek, label: "cv", token: "test-token")
        let snapshot = try UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06 (Paid: $8.06 / Granted: $0.00)"),
            secondary: nil,
            details: [ProviderDetailSection(rows: [
                ProviderDetailSection.Row(label: "Today", value: "$0.1000 · 100 tokens"),
            ])],
            deepseekDetailedUsageState: .available,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())
        fixture.store.snapshots[.deepseek] = snapshot
        fixture.store.lastKnownResetSnapshots[.deepseek] = snapshot
        let context = fixture.settingsContext(provider: .deepseek)
        let picker = try #require(DeepSeekProviderImplementation().settingsPickers(context: context).first)

        picker.binding.wrappedValue = "chrome:Profile 2"
        fixture.store.refreshingProviders.insert(.deepseek)
        fixture.store.reconcileSelectedTokenAccountSnapshotBeforeRefresh(
            provider: .deepseek,
            accounts: fixture.settings.tokenAccounts(for: .deepseek))

        #expect(fixture.store.snapshots[.deepseek] == nil)
        #expect(fixture.store.lastKnownResetSnapshots[.deepseek] == nil)
        let model = ProvidersPane(settings: fixture.settings, store: fixture.store)
            ._test_menuCardModel(for: .deepseek)
        #expect(model.metrics.first?.statusText == "$8.06 (Paid: $8.06 / Granted: $0.00)")
        #expect(model.inlineUsageDashboard == nil)
        #expect(model.usageNotes.isEmpty)
        #expect(!ProvidersPane(settings: fixture.settings, store: fixture.store)
            ._test_providerSubtitle(.deepseek).contains("usage not fetched yet"))
        let transitionPicker = try #require(DeepSeekProviderImplementation().settingsPickers(context: context).first)
        #expect(transitionPicker.options.map(\.id) == ["chrome:Default", "chrome:Profile 2"])
        #expect(!(transitionPicker.isEnabled?() ?? true))

        fixture.store.refreshingProviders.remove(.deepseek)
        #expect(fixture.store.presentationSnapshot(for: .deepseek)?.primary != nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek)?.details.isEmpty == true)

        fixture.store.clearDeepSeekProfileTransition()
        #expect(fixture.store.presentationSnapshot(for: .deepseek) == nil)
    }

    @Test
    func `deepseek selected account success clears its profile transition`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-transition-success")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06"),
            secondary: nil,
            updatedAt: Date())
        fixture.store.beginDeepSeekProfileTransition()
        let refreshed = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$7.50"),
            secondary: nil,
            updatedAt: Date())

        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(
                result: .success(ProviderFetchResult(
                    usage: refreshed,
                    credits: nil,
                    sourceLabel: "api",
                    strategyID: "deepseek.api",
                    strategyKind: .apiToken)),
                attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)

        #expect(fixture.store.deepseekProfileTransitionSnapshot == nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek)?.primary?.resetDescription == "$7.50")
    }

    @Test
    func `deepseek timeout keeps the validated profile catalog with the refreshed balance`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-timeout-catalog")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06"),
            secondary: nil,
            deepseekDetailedUsageState: .available,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())
        fixture.store.beginDeepSeekProfileTransition()
        let refreshedBalance = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$7.50"),
            secondary: nil,
            deepseekDetailedUsageState: .unavailable,
            deepseekPlatformProfiles: [],
            updatedAt: Date())

        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(
                result: .success(ProviderFetchResult(
                    usage: refreshedBalance,
                    credits: nil,
                    sourceLabel: "api",
                    strategyID: "deepseek.api",
                    strategyKind: .apiToken)),
                attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)

        #expect(fixture.store.deepseekProfileTransitionSnapshot == nil)
        #expect(fixture.store.snapshots[.deepseek]?.primary?.resetDescription == "$7.50")
        #expect(fixture.store.snapshots[.deepseek]?.deepseekPlatformProfiles.map(\.id) == [
            "chrome:Default",
            "chrome:Profile 2",
        ])
        let picker = try #require(DeepSeekProviderImplementation()
            .settingsPickers(context: fixture.settingsContext(provider: .deepseek)).first)
        #expect(picker.options.map(\.id) == ["", "chrome:Default", "chrome:Profile 2"])
    }

    @Test
    func `deepseek selected account failure preserves its balance only transition`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-transition-failure")
        fixture.store.snapshots[.deepseek] = try UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06"),
            secondary: nil,
            details: [ProviderDetailSection(rows: [
                ProviderDetailSection.Row(label: "Today", value: "100 tokens"),
            ])],
            deepseekDetailedUsageState: .available,
            updatedAt: Date())
        fixture.store.beginDeepSeekProfileTransition()

        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(
                result: .failure(DeepSeekUsageError.apiError("offline")),
                attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)

        #expect(fixture.store.deepseekProfileTransitionSnapshot != nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek)?.primary?.resetDescription == "$8.06")
        #expect(fixture.store.presentationSnapshot(for: .deepseek)?.details.isEmpty == true)
    }

    @Test
    func `disabling deepseek clears a failed profile transition`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-disable-transition")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06"),
            secondary: nil,
            updatedAt: Date())
        fixture.store.beginDeepSeekProfileTransition()
        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(
                result: .failure(DeepSeekUsageError.apiError("offline")),
                attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek) != nil)

        fixture.store.clearDisabledProviderState(enabledProviders: [])

        #expect(fixture.store.deepseekProfileTransitionSnapshot == nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek) == nil)
    }

    @Test
    func `deepseek requires explicit replacement when the stored profile expires`() throws {
        let apiKey = "test-deepseek-api-key"
        let fixture = try self.makeSettingsFixture(
            suite: "ProviderSettingsDescriptorTests-deepseek-expired-selection",
            environmentBase: [DeepSeekSettingsReader.apiKeyEnvironmentKey: apiKey])
        fixture.settings.setDeepSeekProfileID("chrome:Default", apiKey: apiKey)
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            deepseekDetailedUsageState: .profileSelectionRequired,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())

        let picker = try #require(DeepSeekProviderImplementation()
            .settingsPickers(context: fixture.settingsContext(provider: .deepseek)).first)
        #expect(picker.options.map(\.id) == ["", "chrome:Profile 2"])
        #expect(picker.binding.wrappedValue.isEmpty)
    }

    @Test
    func `deepseek profile transition does not cross api token account selection`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-account-transition")
        fixture.settings.addTokenAccount(provider: .deepseek, label: "Personal", token: "token-1")
        fixture.settings.addTokenAccount(provider: .deepseek, label: "Work", token: "token-2")
        let workAccount = try #require(fixture.settings.selectedTokenAccount(for: .deepseek))
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06 Work"),
            secondary: nil,
            updatedAt: Date())
        fixture.settings.setDeepSeekProfileID("chrome:Profile 2", apiKey: workAccount.token)
        fixture.store.beginDeepSeekProfileTransition()

        fixture.settings.setActiveTokenAccountIndex(0, for: .deepseek)
        let personalAccount = try #require(fixture.settings.selectedTokenAccount(for: .deepseek))
        #expect(personalAccount.id != workAccount.id)
        fixture.store.reconcileSelectedTokenAccountSnapshotBeforeRefresh(
            provider: .deepseek,
            accounts: fixture.settings.tokenAccounts(for: .deepseek))

        #expect(fixture.settings.deepseekProfileID(apiKey: personalAccount.token).isEmpty)
        #expect(fixture.store.deepseekProfileTransitionSnapshot != nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek) == nil)
    }

    @Test
    func `replacing a deepseek key in the same account clears its profile selection`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-replaced-key")
        fixture.settings.addTokenAccount(provider: .deepseek, label: "Account", token: "old-key")
        let account = try #require(fixture.settings.selectedTokenAccount(for: .deepseek))
        fixture.settings.setDeepSeekProfileID("chrome:Default", apiKey: account.token)
        #expect(fixture.settings.deepseekProfileID(apiKey: account.token) == "chrome:Default")

        fixture.settings.updateTokenAccount(
            provider: .deepseek,
            accountID: account.id,
            token: "new-key")

        #expect(fixture.settings.deepseekProfileID(apiKey: "new-key").isEmpty)
        #expect(fixture.settings.providerConfig(for: .deepseek)?.sanitizedDeepSeekProfileID == "chrome:Default")
    }

    @Test
    func `deepseek detailed usage requires cost extras and active api token account`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-account-usage")
        fixture.settings.showOptionalCreditsAndExtraUsage = true
        fixture.settings.costSummaryOption = .inlineSummary
        #expect(fixture.settings.costSummaryShowsInline(for: .deepseek))
        fixture.settings.addTokenAccount(provider: .deepseek, label: "Personal", token: "token-1")
        fixture.settings.addTokenAccount(provider: .deepseek, label: "Work", token: "token-2")
        let accounts = fixture.settings.tokenAccounts(for: .deepseek)
        let active = try #require(fixture.settings.selectedTokenAccount(for: .deepseek))
        let inactive = try #require(accounts.first(where: { $0.id != active.id }))

        #expect(ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .deepseek,
            settings: fixture.settings,
            override: TokenAccountOverride(provider: .deepseek, account: active)))
        #expect(!ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .deepseek,
            settings: fixture.settings,
            override: TokenAccountOverride(provider: .deepseek, account: inactive)))
        fixture.settings.costSummaryOption = .costSubmenu
        #expect(!fixture.settings.costSummaryShowsInline(for: .deepseek))
        #expect(ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .deepseek,
            settings: fixture.settings,
            override: TokenAccountOverride(provider: .deepseek, account: active)))
        fixture.settings.costSummaryOption = .both
        #expect(fixture.settings.costSummaryShowsInline(for: .deepseek))
        fixture.settings.costSummaryOption = .off
        #expect(!fixture.settings.costSummaryShowsInline(for: .deepseek))
        #expect(!ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .deepseek,
            settings: fixture.settings,
            override: TokenAccountOverride(provider: .deepseek, account: active)))
        fixture.settings.showOptionalCreditsAndExtraUsage = false
        #expect(!ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .claude,
            settings: fixture.settings,
            override: nil))
        fixture.settings.costSummaryOption = .inlineSummary
        #expect(!ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .deepseek,
            settings: fixture.settings,
            override: TokenAccountOverride(provider: .deepseek, account: active)))
    }

    @Test
    func `provider settings labels an empty transition as refreshing`() {
        #expect(ProviderMetricsInlineView.placeholderText(
            isEnabled: true,
            isRefreshing: true,
            modelPlaceholder: nil) == "Refreshing")
        #expect(ProviderMetricsInlineView.placeholderText(
            isEnabled: true,
            isRefreshing: false,
            modelPlaceholder: nil) == "No usage yet")
    }

    @Test
    func `deepseek hides profile picker when only one validated profile remains`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-single-profile")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
            ],
            updatedAt: Date())
        let context = fixture.settingsContext(provider: .deepseek)

        #expect(DeepSeekProviderImplementation().settingsPickers(context: context).isEmpty)
    }
}

extension ProviderSettingsDescriptorTests {
    func makeSettingsFixture(
        suite: String,
        environmentBase: [String: String] = [:]) throws -> ProviderSettingsFixture
    {
        let defaults = InMemoryUserDefaults()
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: environmentBase)
        return ProviderSettingsFixture(settings: settings, store: store)
    }

    struct ProviderSettingsFixture {
        let settings: SettingsStore
        let store: UsageStore
        private let state = ProviderSettingsContextState()

        @MainActor
        func settingsContext(
            provider: UsageProvider,
            runLoginFlow: @escaping () async -> Void = {}) -> ProviderSettingsContext
        {
            let settings = self.settings
            let store = self.store
            let state = self.state
            return ProviderSettingsContext(
                provider: provider,
                settings: settings,
                store: store,
                statusText: { id in state.statusByID[id] },
                setStatusText: { id, text in
                    if let text {
                        state.statusByID[id] = text
                    } else {
                        state.statusByID.removeValue(forKey: id)
                    }
                },
                lastAppActiveRunAt: { id in state.lastRunAtByID[id] },
                setLastAppActiveRunAt: { id, date in
                    if let date {
                        state.lastRunAtByID[id] = date
                    } else {
                        state.lastRunAtByID.removeValue(forKey: id)
                    }
                },
                requestConfirmation: { _ in },
                runLoginFlow: runLoginFlow)
        }

        @MainActor
        func presentationContext(provider: UsageProvider, metadata: ProviderMetadata) -> ProviderPresentationContext {
            ProviderPresentationContext(
                provider: provider,
                settings: self.settings,
                store: self.store,
                metadata: metadata)
        }
    }

    private final class ProviderSettingsContextState {
        var statusByID: [String: String] = [:]
        var lastRunAtByID: [String: Date] = [:]
    }
}
