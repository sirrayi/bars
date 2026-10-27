import AppKit
import BarsCore
import SwiftUI

@MainActor
enum ProviderSettingsRefreshInteraction {
    static func perform<Result>(operation: () async -> Result) async -> Result {
        await BrowserCookieAccessGate.withExplicitRetry {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await operation()
            }
        }
    }
}

@MainActor
struct ProvidersPane: View {
    let provider: UsageProvider
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    let runProviderLoginFlow: @MainActor (UsageProvider) async -> Void
    @State private var expandedErrors: Set<UsageProvider> = []
    @State private var settingsStatusTextByID: [String: String] = [:]
    @State private var settingsLastAppActiveRunAtByID: [String: Date] = [:]
    @State private var activeConfirmation: ProviderSettingsConfirmationState?

    init(
        provider: UsageProvider = .claude,
        settings: SettingsStore,
        store: UsageStore,
        runProviderLoginFlow: @escaping @MainActor (UsageProvider) async -> Void = { _ in })
    {
        self.provider = provider
        self.settings = settings
        self.store = store
        self.runProviderLoginFlow = runProviderLoginFlow
    }

    var body: some View {
        let unfilteredModel = UsageMenuCardView.Model.make(self.store.menuCardInput(
            for: self.provider, context: .settings))
        let visibilityModel = UsageMenuCardView.Model.make(self.store.menuCardInput(
            for: self.provider, context: .settings, optionalUsageOverride: true))
        let usageItems = visibilityModel.usageItemDescriptors(
            includingHidden: self.settings.hiddenUsageItemIDs(for: self.provider),
            hidePersonalInfo: self.settings.hidePersonalInfo)
            .reduce(into: [ProviderUsageItemDescriptor]()) { items, item in
                if !items.contains(where: { $0.id == item.id }) { items.append(item) }
            }
        ProviderDetailView(
            provider: self.provider,
            store: self.store,
            isEnabled: self.binding(for: self.provider),
            subtitle: self.providerSubtitle(self.provider),
            model: unfilteredModel.applyingUsageItemVisibility(
                hiddenItemIDs: self.settings.hiddenUsageItemIDs(for: self.provider)),
            usageItems: usageItems,
            settingsPickers: self.extraSettingsPickers(for: self.provider),
            settingsToggles: self.extraSettingsToggles(for: self.provider),
            settingsFields: self.extraSettingsFields(for: self.provider),
            settingsDirectoryLists: self.extraSettingsDirectoryLists(for: self.provider),
            settingsModelLimits: self.extraSettingsModelLimits(for: self.provider),
            settingsActions: self.extraSettingsActions(for: self.provider),
            settingsTokenAccounts: self.tokenAccountDescriptor(for: self.provider),
            settingsOrganizations: self.extraSettingsOrganizations(for: self.provider),
            errorDisplay: self.providerErrorDisplay(self.provider),
            isErrorExpanded: self.expandedBinding(for: self.provider),
            onCopyError: { text in self.copyToPasteboard(text) },
            onRefresh: {
                self.triggerRefresh(for: self.provider)
            })
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                self.runSettingsDidBecomeActiveHooks()
            }
            .alert(
                self.activeConfirmation?.title ?? "",
                isPresented: Binding(
                    get: { self.activeConfirmation != nil },
                    set: { isPresented in
                        if !isPresented {
                            self.activeConfirmation = nil
                        }
                    }),
                actions: {
                    if let active = self.activeConfirmation {
                        Button(active.confirmTitle) {
                            active.onConfirm()
                            self.activeConfirmation = nil
                        }
                        Button(L("cancel"), role: .cancel) { self.activeConfirmation = nil }
                    }
                },
                message: {
                    if let active = self.activeConfirmation {
                        Text(active.message)
                    }
                })
    }

    static func filteredProviders(
        _ providers: [UsageProvider],
        query: String,
        displayName: (UsageProvider) -> String) -> [UsageProvider]
    {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return providers }
        return providers.filter { provider in
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            let fields = [
                displayName(provider),
                descriptor.metadata.shortDisplayName,
                provider.rawValue,
                descriptor.cli.name,
            ] + descriptor.cli.aliases
            return words.allSatisfy { word in
                fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
    }

    func moveProviders(fromOffsets: IndexSet, toOffset: Int) {
        self.settings.moveVisibleProviders(
            self.settings.orderedFirstPartyProviders().map(\.instanceID),
            fromOffsets: fromOffsets,
            toOffset: toOffset)
    }

    private func triggerRefresh(for provider: UsageProvider) {
        Task { @MainActor in
            await ProviderSettingsRefreshInteraction.perform {
                await self.store.refreshProvider(provider, allowDisabled: true)
            }
        }
    }

    func binding(for provider: UsageProvider) -> Binding<Bool> {
        let meta = self.store.metadata(for: provider)
        return Binding(
            get: { self.settings.isProviderEnabled(provider: provider, metadata: meta) },
            set: { newValue in
                self.settings.setProviderEnabled(provider: provider, metadata: meta, enabled: newValue)
            })
    }

    private func providerUsageText(_ provider: UsageProvider) -> String {
        if self.store.isStale(provider: provider) { return L("last_fetch_failed") }
        let snapshot = self.store.presentationSnapshot(for: provider)
        // Successful refreshes clear remembered availability; resolve quota-less successes from the snapshot.
        let availability = self.store.knownLimitsAvailability(for: provider)
            ?? UsageLimitsAvailability.resolve(provider: provider, snapshot: snapshot)
        if availability.isUnavailable { return L("Limits not available") }
        return snapshot?.updatedAt.relativeDescription() ?? L("usage_not_fetched_yet")
    }

    func providerSubtitle(_ provider: UsageProvider) -> String {
        let meta = self.store.metadata(for: provider)
        let presentationContext = ProviderPresentationContext(
            provider: provider,
            settings: self.settings,
            store: self.store,
            metadata: meta)
        let presentation = ProviderCatalog.implementation(for: provider)?
            .presentation(context: presentationContext)
            ?? ProviderPresentation(detailLine: ProviderPresentation.standardDetailLine)
        let detailLine = presentation.detailLine(presentationContext)

        return "\(detailLine)\n\(self.providerUsageText(provider))"
    }

    func providerSidebarSubtitle(_ provider: UsageProvider) -> String {
        let meta = self.store.metadata(for: provider)
        let detailLine: String = if let sourceLabel = self.store.lastSourceLabels[provider.instanceID],
                                    !sourceLabel.isEmpty
        {
            sourceLabel
        } else if let version = self.store.version(for: provider), !version.isEmpty {
            "\(meta.cliName) \(version)"
        } else {
            meta.cliName
        }

        return "\(detailLine)\n\(self.providerUsageText(provider))"
    }

    func providerErrorDisplay(_ provider: UsageProvider) -> ProviderErrorDisplay? {
        guard let full = self.store.error(for: provider) ?? self.store.diagnostic(for: provider),
              !full.isEmpty
        else { return nil }
        let preview = self.store.userFacingError(for: provider) ?? full
        return ProviderErrorDisplay(
            preview: self.truncated(preview, prefix: ""),
            full: full)
    }

    private func extraSettingsToggles(for provider: UsageProvider) -> [ProviderSettingsToggleDescriptor] {
        guard let impl = ProviderCatalog.implementation(for: provider) else { return [] }
        let context = self.makeSettingsContext(provider: provider)
        return impl.settingsToggles(context: context)
            .filter { $0.isVisible?() ?? true }
    }

    private func extraSettingsPickers(for provider: UsageProvider) -> [ProviderSettingsPickerDescriptor] {
        guard let impl = ProviderCatalog.implementation(for: provider) else { return [] }
        let context = self.makeSettingsContext(provider: provider)
        // The token layout editor is the only text-style menu bar UI. Legacy metric keys remain persisted solely for
        // migration and downgrade safety, so provider settings no longer append their former menu bar metric picker.
        return impl.settingsPickers(context: context)
            .filter { $0.isVisible?() ?? true }
    }

    private func extraSettingsFields(for provider: UsageProvider) -> [ProviderSettingsFieldDescriptor] {
        guard let impl = ProviderCatalog.implementation(for: provider) else { return [] }
        let context = self.makeSettingsContext(provider: provider)
        return impl.settingsFields(context: context)
            .filter { $0.isVisible?() ?? true }
    }

    private func extraSettingsModelLimits(for provider: UsageProvider) -> [ProviderSettingsModelLimitsDescriptor] {
        ProviderCatalog.implementation(for: provider)?
            .settingsModelLimits(context: self.makeSettingsContext(provider: provider)) ?? []
    }

    private func extraSettingsDirectoryLists(for provider: UsageProvider) -> [ProviderSettingsDirectoryListDescriptor] {
        ProviderCatalog.implementation(for: provider)?
            .settingsDirectoryLists(context: self.makeSettingsContext(provider: provider)) ?? []
    }

    private func extraSettingsActions(for provider: UsageProvider) -> [ProviderSettingsActionsDescriptor] {
        guard let impl = ProviderCatalog.implementation(for: provider) else { return [] }
        let context = self.makeSettingsContext(provider: provider)
        return impl.settingsActions(context: context)
            .filter { $0.isVisible?() ?? true }
    }

    private func extraSettingsOrganizations(
        for provider: UsageProvider) -> ProviderSettingsOrganizationsDescriptor?
    {
        guard let impl = ProviderCatalog.implementation(for: provider) else { return nil }
        let context = self.makeSettingsContext(provider: provider)
        return impl.settingsOrganizations(context: context)
    }

    func tokenAccountDescriptor(for provider: UsageProvider) -> ProviderSettingsTokenAccountsDescriptor? {
        guard let support = TokenAccountSupportCatalog.support(for: provider) else { return nil }
        let context = self.makeSettingsContext(provider: provider)
        let implementation = ProviderCatalog.implementation(for: provider)
        var descriptor = ProviderSettingsTokenAccountsDescriptor(
            id: "token-accounts-\(provider.rawValue)",
            title: support.title,
            subtitle: support.subtitle,
            placeholder: support.placeholder,
            provider: provider,
            isVisible: {
                ProviderCatalog.implementation(for: provider)?
                    .tokenAccountsVisibility(context: context, support: support)
                    ?? (!support.requiresManualCookieSource ||
                        !context.settings.tokenAccounts(for: provider).isEmpty)
            },
            accounts: { self.settings.tokenAccounts(for: provider) },
            activeIndex: {
                let data = self.settings.tokenAccountsData(for: provider)
                return data?.clampedActiveIndex() ?? 0
            },
            setActiveIndex: { index in
                self.settings.setActiveTokenAccountIndex(index, for: provider)
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(provider, allowDisabled: true)
                    }
                }
            },
            showsOrganizationField: support.showsOrganizationField,
            showsTeamModeControls: support.showsTeamModeControls,
            addAccount: { label, token, usageScope, organizationID, workspaceID, claudeConfigDirectory in
                self.settings.addTokenAccount(
                    provider: provider,
                    label: label,
                    token: token,
                    usageScope: usageScope,
                    organizationID: organizationID,
                    workspaceID: workspaceID,
                    claudeConfigDirectory: claudeConfigDirectory)
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(provider, allowDisabled: true)
                    }
                }
            },
            updateAccount: { accountID, usageScope, organizationID, workspaceID in
                self.settings.updateTokenAccount(
                    provider: provider,
                    accountID: accountID,
                    usageScope: usageScope,
                    organizationID: organizationID,
                    workspaceID: workspaceID)
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(provider, allowDisabled: true)
                    }
                }
            },
            removeAccount: { accountID in
                self.settings.removeTokenAccount(provider: provider, accountID: accountID)
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(provider, allowDisabled: true)
                    }
                }
            },
            primaryAddActionTitle: support.primaryAddActionTitle,
            primaryAddAction: support.primaryAddActionTitle.map { _ in {
                await implementation?.runTokenAccountPrimaryAction(context: context)
                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await self.store.refreshProvider(provider, allowDisabled: true)
                }
            } },
            openConfigFile: {
                if implementation?.openTokenFile(context: context) == true {
                    return
                }
                self.settings.openTokenAccountsFile()
            },
            reloadFromDisk: {
                self.settings.reloadTokenAccounts()
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(provider, allowDisabled: true)
                    }
                }
            })
        descriptor.editAccount = { accountID, label, token in
            self.settings.updateTokenAccount(provider: provider, accountID: accountID, label: label, token: token)
        }
        descriptor.moveAccount = { accountID, destination in
            self.settings.moveTokenAccount(provider: provider, accountID: accountID, to: destination)
        }
        // Provider-specific by design: only Claude accounts declare local transcript ownership.
        if provider == .claude {
            descriptor.claudeConfigDirectory = { accountID in
                Binding(
                    get: { self.settings.tokenAccounts(for: provider)
                        .first(where: { $0.id == accountID })?.claudeConfigDirectory
                    },
                    set: { directory in
                        self.settings.updateTokenAccount(
                            provider: provider, accountID: accountID, claudeConfigDirectory: .some(directory))
                    })
            }
        }
        return descriptor
    }

    private func makeSettingsContext(provider: UsageProvider) -> ProviderSettingsContext {
        ProviderSettingsContext(
            provider: provider,
            settings: self.settings,
            store: self.store,
            statusText: { id in
                self.settingsStatusTextByID[id]
            },
            setStatusText: { id, text in
                if let text {
                    self.settingsStatusTextByID[id] = text
                } else {
                    self.settingsStatusTextByID.removeValue(forKey: id)
                }
            },
            lastAppActiveRunAt: { id in
                self.settingsLastAppActiveRunAtByID[id]
            },
            setLastAppActiveRunAt: { id, date in
                if let date {
                    self.settingsLastAppActiveRunAtByID[id] = date
                } else {
                    self.settingsLastAppActiveRunAtByID.removeValue(forKey: id)
                }
            },
            requestConfirmation: { confirmation in
                self.activeConfirmation = ProviderSettingsConfirmationState(confirmation: confirmation)
            },
            runLoginFlow: {
                await self.runProviderLoginFlow(provider)
            })
    }

    private func runSettingsDidBecomeActiveHooks() {
        for provider in UsageProvider.allCases {
            for toggle in self.extraSettingsToggles(for: provider) {
                guard let hook = toggle.onAppDidBecomeActive else { continue }
                Task { @MainActor in
                    await hook()
                }
            }
        }
    }

    private func truncated(_ text: String, prefix: String, maxLength: Int = 160) -> String {
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.count > maxLength {
            let idx = message.index(message.startIndex, offsetBy: maxLength)
            message = "\(message[..<idx])…"
        }
        return prefix + message
    }

    private func expandedBinding(for provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { self.expandedErrors.contains(provider) },
            set: { expanded in
                if expanded {
                    self.expandedErrors.insert(provider)
                } else {
                    self.expandedErrors.remove(provider)
                }
            })
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

@MainActor
struct ProviderSettingsConfirmationState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let onConfirm: () -> Void

    init(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void)
    {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
    }

    init(confirmation: ProviderSettingsConfirmation) {
        self.title = L(confirmation.title)
        self.message = L(confirmation.message)
        self.confirmTitle = L(confirmation.confirmTitle)
        self.onConfirm = confirmation.onConfirm
    }
}
