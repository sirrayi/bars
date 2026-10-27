import AppKit
import BarsCore
import Observation
import QuartzCore
import SwiftUI

// MARK: - NSMenu construction

extension StatusItemController {
    static let menuCardBaseWidth: CGFloat = 310
    private static let maxOverviewProviders = SettingsStore.mergedOverviewProviderLimit
    static let overviewRowIdentifierPrefix = "overviewRow-"
    static let persistentRefreshMenuItemID = "persistentRefreshAction"
    private static let defaultMenuOpenRefreshDelay: Duration = .seconds(1.2)
    #if DEBUG
    private static var menuOpenRefreshDelayForTesting: Duration = .seconds(1.2)
    static func setMenuOpenRefreshDelayForTesting(_ delay: Duration) {
        self.menuOpenRefreshDelayForTesting = delay
    }

    static func resetMenuOpenRefreshDelayForTesting() {
        self.menuOpenRefreshDelayForTesting = self.defaultMenuOpenRefreshDelay
    }
    #endif

    private static var menuOpenRefreshDelay: Duration {
        #if DEBUG
        menuOpenRefreshDelayForTesting
        #else
        defaultMenuOpenRefreshDelay
        #endif
    }

    static let costHistoryChartID = "costHistoryChart"
    static let usageHistoryChartID = "usageHistoryChart"
    static let storageBreakdownID = "storageBreakdown"
    static let statusComponentsID = "statusComponents"

    func shortcut(for action: MenuDescriptor.MenuAction) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        switch action {
        case .refresh:
            ("r", [.command])
        case .settings:
            (",", [.command])
        case .quit:
            ("q", [.command])
        default:
            nil
        }
    }

    func makeMenu() -> NSMenu {
        guard self.shouldMergeIcons else {
            return self.makeMenu(for: nil)
        }
        return self.makeBaseMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard self.shouldMergeIcons, menu === self.mergedMenu else { return }
        self.refreshMenuForOpenIfNeeded(menu, provider: self.resolvedMenuProvider())
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu.supermenu == nil {
            // Records interaction and may bring an adaptive timer forward; never refreshes
            // synchronously. Root opens only: hover-opening a hosted chart submenu must not kick
            // off an agent-session rescan — the scan completion invalidates the tracked parent
            // while its submenu is open, and on the Overview tab the resulting structural parent
            // rebuild force-closes the hovered submenu. Each reopen then triggered another rescan,
            // producing an infinite open/close/rebuild flicker loop (#2652).
            self.store.noteMenuOpened()
            self.agentSessions.refreshOnMenuOpen()
        }

        let trace = self.beginMenuOperationTrace("menuWillOpen", breadcrumb: "menuWillOpen")
        defer { self.endMenuOperationTrace(trace, menu: menu, provider: self.menuProvider(for: menu)) }

        // Keep the menu drawing in the current system appearance rather than the menu bar's
        // (possibly dark) vibrant appearance. Done before any early return so submenus match too.
        StatusMenuAppearance.pin(menu)

        self.cancelDeferredMenuInteractionRefreshTask()
        self.cancelClosedMenuRebuild(menu)

        self.beginMenuTrackingSession(for: menu)

        // Track whether this is the root menu opening (no menus were open). Only the root open rebuilds
        // all content from current data, so the readiness baseline is re-anchored only here — re-anchoring
        // on a nested submenu open could mask a pending refresh for the already-open parent menu.
        let menuTrackingWasIdle = self.openMenus.isEmpty

        if self.isHostedSubviewMenu(menu) {
            if !self.hydrateHostedSubviewMenuIfNeeded(menu) {
                self.refreshHostedSubviewMenu(menu)
            }
            if self.isMenuRefreshEnabled {
                // Intentionally skip open-menu tracking when refresh is disabled (tests).
                // If refresh is re-enabled while this menu stays open, it will not be backfilled until next open.
                self.openMenus[ObjectIdentifier(menu)] = menu
                if menuTrackingWasIdle {
                    self.resyncMenuAdjunctReadinessBaseline()
                }
            }
            // Removed redundant async refresh - single pass is sufficient after initial layout
            return
        }

        var provider: UsageProvider?
        if self.shouldMergeIcons {
            let enabledProviders = self.store.enabledFirstPartyProvidersForDisplay()
            _ = self.resolvedMergedMenuSelection(enabledProviders: enabledProviders)
            let resolvedProvider = self.resolvedMenuProvider(enabledProviders: enabledProviders)
            self.lastMenuProvider = (resolvedProvider ?? .claude).instanceID
            provider = resolvedProvider
        } else {
            if let menuProvider = self.menuProviders[ObjectIdentifier(menu)] {
                self.lastMenuProvider = menuProvider
                provider = menuProvider.firstPartyProvider
            } else if menu === self.fallbackMenu {
                self.lastMenuProvider = self.store.enabledProvidersForDisplay().first ?? .claude
                provider = nil
            } else {
                let resolved = self.store.enabledProvidersForDisplay().first ?? .claude
                self.lastMenuProvider = resolved
                provider = resolved.firstPartyProvider
            }
        }

        if self.settings.providerStorageFootprintsEnabled {
            self.store.refreshStorageFootprintsForOverview()
        }

        let menuWasFreshBeforeOpen = !self.menuNeedsRefresh(menu)
        self.refreshMenuForOpenIfNeeded(menu, provider: provider)
        if self.isMenuRefreshEnabled {
            // Intentionally skip open-menu tracking when refresh is disabled (tests).
            // If refresh is re-enabled while this menu stays open, it will not be backfilled until next open.
            self.openMenus[ObjectIdentifier(menu)] = menu
            // Only re-anchor when the opened menu actually shows current data. During an in-flight provider
            // refresh `refreshMenuForOpenIfNeeded` can preserve stale content; resyncing the baseline to
            // live store data in that case would mask the refresh-completion update (#1351).
            if menuTrackingWasIdle, !self.menuNeedsRefresh(menu) {
                self.resyncMenuAdjunctReadinessBaselineForRootOpen(
                    menu,
                    provider: provider,
                    menuWasFreshBeforeOpen: menuWasFreshBeforeOpen)
            }
            self.installProviderSwitcherShortcutMonitorIfNeeded(for: menu)
            // Only schedule refresh after menu is registered as open - refreshNow is called async
            self.scheduleOpenMenuRefresh(for: menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        let wasHostedSubviewMenu = self.isHostedSubviewMenu(menu)
        self.forgetClosedMenu(menu)
        if wasHostedSubviewMenu {
            self.refreshOpenMenusAfterHostedSubviewClose()
        }
        if self.openMenus.isEmpty {
            self.cancelMergedSwitcherSiblingWarmup()
            self.resetClaudeSwapAccountInspection()
        }
        self.resetCompactAccountMenuExpansionStateIfIdle()
    }

    func forgetClosedMenu(_ menu: NSMenu) {
        let key = ObjectIdentifier(menu)
        let wasMergedMenu = menu === self.mergedMenu

        self.endMenuTrackingSession(for: menu)

        if key == self.providerSwitcherShortcutMenuID {
            self.removeProviderSwitcherShortcutMonitor()
        }

        self.clearMergedSwitcherContentCache(for: menu)
        let wasTracked = self.openMenus.removeValue(forKey: key) != nil
        let menuTrackingEnded = wasTracked && self.openMenus.isEmpty
        if self.openMenus.isEmpty {
            self.parentMenuRebuildPendingAfterHostedSubviewClose = false
        }
        self.cancelMenuWork(key)
        self.clearMenuHighlight(key)

        let isPersistentMenu = menu === self.mergedMenu ||
            menu === self.fallbackMenu ||
            self.providerMenus.values.contains { $0 === menu }
        if !isPersistentMenu {
            self.removeMenuTrackingState(key)
        } else if self.menuNeedsRefresh(menu) {
            self.handleClosedPersistentMenuNeedingRefresh(menu)
        }
        self.menuSession.clearParentRebuildDeferral(key)
        self.scheduleDeferredMenuInteractionRefreshIfNeeded()
        if wasMergedMenu {
            self.applyDeferredMergedIconRenderAfterTrackingIfNeeded()
        }
        if menuTrackingEnded {
            self.prepareAttachedClosedMenusIfNeeded()
        }
    }

    func populateMenu(_ menu: NSMenu, provider: UsageProvider?) {
        let trace = self.beginMenuOperationTrace(
            "populateMenu",
            breadcrumb: "populateMenu:\(provider?.rawValue ?? "merged")")
        defer { self.endMenuOperationTrace(trace, menu: menu, provider: provider) }
        defer { self.refreshMenuCardHeights(in: menu) }
        // Re-warm sibling tab caches after every populate of the open merged menu so a
        // tab switch attaches pre-rendered rows; no-ops for closed or non-merged menus.
        defer { self.scheduleMergedSwitcherSiblingWarmup(for: menu) }

        let enabledProviders = self.store.enabledFirstPartyProvidersForDisplay()
        let switcherProviderIDs = self.switcherProviderIDs(enabledFirstPartyProviders: enabledProviders)
        let includesOverview = self.includesOverviewTab(enabledProviders: enabledProviders)
        let switcherSelection = self.resolvedMergedMenuSelection(enabledProviders: enabledProviders)
        let isOverviewSelected = switcherSelection == .overview
        let isPluginSelected = false
        let selectedProvider: UsageProvider? = switch switcherSelection {
        case .overview: self.resolvedMenuProvider(enabledProviders: enabledProviders)
        case let .provider(instanceID): instanceID.firstPartyProvider
        case nil: provider
        }
        let currentProvider = selectedProvider ?? enabledProviders.first ?? .claude
        let suppressAccountSwitchers = isOverviewSelected || isPluginSelected
        let tokenAccountDisplay = suppressAccountSwitchers ? nil : self.tokenAccountMenuDisplay(for: currentProvider)
        let showAllAccounts = tokenAccountDisplay?.showAll ?? false
        let submenuContext = self.menuSubmenuContext(
            currentProvider: currentProvider,
            showAllAccounts: showAllAccounts)
        let descriptor = self.makeMenuDescriptor(
            provider: selectedProvider,
            includeContextualActions: !isOverviewSelected && !isPluginSelected)
        let menuWidth = self.menuCardWidth(
            for: enabledProviders,
            selectedProvider: selectedProvider,
            descriptor: descriptor)

        let hasTokenSwitcher = menu.items.contains { $0.view is TokenAccountSwitcherView }
        let switcherProvidersMatch = switcherProviderIDs == self.lastSwitcherProviders
        let switcherUsageBarsShowUsedMatch = self.settings.usageBarsShowUsed == self.lastSwitcherUsageBarsShowUsed
        let switcherSelectionMatches = switcherSelection == self.lastMergedSwitcherSelection
        let switcherOverviewAvailabilityMatches = includesOverview == self.lastSwitcherIncludesOverview
        let menuLocalizationMatches = self.menuLocalizationSignature() == self.lastMenuLocalizationSignature
        let tokenSwitcherCompatible = tokenAccountDisplay == self.lastTokenAccountMenuDisplay &&
            ((tokenAccountDisplay?.showSwitcher == true && hasTokenSwitcher) ||
                (tokenAccountDisplay?.showSwitcher != true && !hasTokenSwitcher))
        let reusableRowWidthsMatch = self.reusableFixedWidthRows(in: menu).allSatisfy { item in
            guard let view = item.view else { return false }
            return abs(view.frame.width - menuWidth) <= 0.5
        }
        let providerSwitcherWidthMatches = (menu.items.first?.view as? ProviderSwitcherView).map { view in
            abs(view.frame.width - menuWidth) <= 0.5
        } ?? false
        let canSmartUpdate = self.shouldMergeIcons &&
            switcherProviderIDs.count > 1 &&
            !isOverviewSelected &&
            switcherProvidersMatch &&
            switcherUsageBarsShowUsedMatch &&
            switcherSelectionMatches &&
            switcherOverviewAvailabilityMatches &&
            menuLocalizationMatches &&
            tokenSwitcherCompatible &&
            reusableRowWidthsMatch &&
            !menu.items.isEmpty &&
            menu.items.first?.view is ProviderSwitcherView

        #if DEBUG
        if self.openMenus[ObjectIdentifier(menu)] != nil {
            self.menuLogger.debug(
                "populateMenu(open): provider=\(String(describing: provider)) " +
                    "display=\(enabledProviders.map(\.rawValue)) " +
                    "available=\(self.store.enabledProviders().map(\.rawValue)) " +
                    "selection=\(String(describing: switcherSelection)) " +
                    "last=\(String(describing: self.lastMergedSwitcherSelection)) " +
                    "smart=\(canSmartUpdate)")
        }
        #endif

        if canSmartUpdate {
            self.updateMenuContentPreservingSwitcher(
                menu,
                context: MenuUpdateContext(
                    provider: selectedProvider,
                    currentProvider: currentProvider,
                    switcherSelection: switcherSelection ?? .provider(currentProvider.instanceID),
                    menuWidth: menuWidth,
                    tokenAccountDisplay: tokenAccountDisplay,
                    submenuContext: submenuContext,
                    descriptor: descriptor))
            return
        }

        let canPreserveProviderSwitcher = self.shouldMergeIcons &&
            switcherProviderIDs.count > 1 &&
            switcherProvidersMatch &&
            switcherUsageBarsShowUsedMatch &&
            switcherOverviewAvailabilityMatches &&
            menuLocalizationMatches &&
            providerSwitcherWidthMatches &&
            !menu.items.isEmpty &&
            menu.items.first?.view is ProviderSwitcherView

        #if DEBUG
        if self.openMenus[ObjectIdentifier(menu)] != nil {
            self.menuLogger.debug(
                "populateMenu(open): preserveSwitcher=\(canPreserveProviderSwitcher) " +
                    "widthMatch=\(providerSwitcherWidthMatches)")
        }
        #endif

        if canPreserveProviderSwitcher {
            self.updateMenuContentPreservingSwitcher(
                menu,
                context: MenuUpdateContext(
                    provider: selectedProvider,
                    currentProvider: currentProvider,
                    switcherSelection: switcherSelection ?? .provider(currentProvider.instanceID),
                    menuWidth: menuWidth,
                    tokenAccountDisplay: tokenAccountDisplay,
                    submenuContext: submenuContext,
                    descriptor: descriptor))
            return
        }

        #if DEBUG
        if self.openMenus[ObjectIdentifier(menu)] != nil, menu.items.first?.view is ProviderSwitcherView {
            self.menuLogger.debug("populateMenu(open): rebuilding whole menu and replacing provider switcher")
        }
        #endif
        MenuSwitchFlickerProbe.debugLog("full-rebuild-path \(String(describing: switcherSelection))")
        self.rebuildMenuContent(
            menu,
            context: MenuRebuildContext(
                enabledProviders: enabledProviders,
                includesOverview: includesOverview,
                switcherSelection: switcherSelection,
                currentProvider: currentProvider,
                selectedProvider: selectedProvider,
                menuWidth: menuWidth,
                tokenAccountDisplay: tokenAccountDisplay,
                submenuContext: submenuContext,
                descriptor: descriptor))
    }

    private func reusableFixedWidthRows(in menu: NSMenu) -> [NSMenuItem] {
        guard !menu.items.isEmpty else { return [] }

        var reusableRows: [NSMenuItem] = []
        let index = self.providerSwitcherContentStartIndex(in: menu)
        if index > 0 {
            reusableRows.append(menu.items[0])
        }
        if menu.items.count > index,
           menu.items[index].view is TokenAccountSwitcherView
        {
            reusableRows.append(menu.items[index])
        }
        return reusableRows
    }

    private func rebuildMenuContent(
        _ menu: NSMenu,
        context: MenuRebuildContext)
    {
        self.performMenuMutationWithoutAnimation {
            defer { self.flushHostedMenuRowRendering(in: menu) }
            let displacedSelection = self.lastMergedMenuContentSelection
            self.lastMergedMenuContentSelection = nil
            self.harvestRecyclableMenuCardViews(in: menu, fromIndex: 0, displacedSelection: displacedSelection)
            defer { self.clearMenuCardViewRecyclePool() }
            menu.removeAllItems()
            let contentSelection = context.switcherSelection ?? .provider(context.currentProvider.instanceID)
            self.addProviderSwitcherIfNeeded(
                to: menu,
                enabledProviders: context.enabledProviders,
                includesOverview: context.includesOverview,
                selection: context.switcherSelection ?? .provider(context.currentProvider.instanceID),
                width: context.menuWidth)
            // Track which providers the switcher was built with for smart update detection
            if self.shouldMergeIcons,
               self.switcherProviderIDs(enabledFirstPartyProviders: context.enabledProviders).count > 1
            {
                self.rememberMergedSwitcherState(
                    context.enabledProviders,
                    context.switcherSelection,
                    context.includesOverview)
            }
            if self.shouldMergeIcons,
               self.switcherProviderIDs(enabledFirstPartyProviders: context.enabledProviders).count > 1,
               self.addCachedMergedSwitcherContent(
                   for: contentSelection,
                   to: menu,
                   menuWidth: context.menuWidth,
                   tokenAccountDisplay: context.tokenAccountDisplay)
            {
                return
            }
            self.addTokenAccountSwitcherIfNeeded(
                to: menu,
                display: context.tokenAccountDisplay,
                width: context.menuWidth)
            self.lastTokenAccountMenuDisplay = context.tokenAccountDisplay
            let menuContext = MenuCardContext(
                currentProvider: context.currentProvider,
                selectedProvider: context.selectedProvider,
                menuWidth: context.menuWidth,
                tokenAccountDisplay: context.tokenAccountDisplay,
                submenuContext: context.submenuContext)
            self.addPrimaryMenuContent(
                to: menu,
                context: menuContext,
                switcherSelection: contentSelection)
            self.addActionableSections(
                context.descriptor.sections, to: menu, width: context.menuWidth, provider: context.currentProvider)
            self.cacheVisibleMergedSwitcherContent(
                in: menu,
                selection: contentSelection,
                contentStartIndex: self.providerSwitcherContentStartIndex(in: menu),
                menuWidth: context.menuWidth,
                contentVersion: self.menuSession.contentVersion)
        }
    }

    func menuSubmenuContext(
        currentProvider: UsageProvider,
        showAllAccounts: Bool) -> MenuSubmenuContext
    {
        let hasCostHistory = self.settings.costSummaryShowsSubmenu(for: currentProvider) &&
            (self.store.tokenSnapshot(for: currentProvider)?.daily.isEmpty == false)
        return MenuSubmenuContext(
            hasCostHistory: hasCostHistory,
            hasSubmenuItems: !showAllAccounts && hasCostHistory)
    }

    private func addProviderSwitcherIfNeeded(
        to menu: NSMenu,
        enabledProviders: [UsageProvider],
        includesOverview: Bool,
        selection: ProviderSwitcherSelection,
        width: CGFloat)
    {
        guard self.shouldMergeIcons,
              self.switcherProviderIDs(enabledFirstPartyProviders: enabledProviders).count > 1
        else { return }
        let switcherItem = self.makeProviderSwitcherItem(
            providers: enabledProviders,
            includesOverview: includesOverview,
            selected: selection,
            menu: menu,
            width: width)
        menu.addItem(switcherItem)
        menu.addItem(.separator())
    }

    func addTokenAccountSwitcherIfNeeded(
        to menu: NSMenu,
        display: TokenAccountMenuDisplay?,
        width: CGFloat,
        captureMenu: NSMenu? = nil)
    {
        guard let display, display.showSwitcher else { return }
        let switcherItem = self.makeTokenAccountSwitcherItem(
            display: display,
            menu: captureMenu ?? menu,
            width: width)
        menu.addItem(switcherItem)
        menu.addItem(.separator())
    }

    @discardableResult
    private func addOverviewRows(
        to menu: NSMenu,
        enabledProviders: [UsageProvider],
        menuWidth: CGFloat,
        captureMenu: NSMenu? = nil) -> Bool
    {
        // Rows may be built into a detached scratch menu for in-place reconciliation;
        // interaction closures must always reference the live menu they end up serving.
        let interactionMenu = captureMenu ?? menu
        let providerScopes = self.overviewProviderScopes(enabledProviders: enabledProviders)
        let rows = self.store.mergedOverviewRows(for: providerScopes.visible)
        guard !rows.isEmpty else { return false }

        let t0 = CACurrentMediaTime()
        defer { self.logChartRenderDurationIfSlow("addOverviewRows(\(rows.count))", startedAt: t0) }

        let spendProviders = providerScopes.spend
        let spendModel = self.overviewSpendDashboardModel(providers: spendProviders)
        let spendProviderCount = self.overviewSpendSubscriptionCount(providers: spendProviders)
        if spendProviderCount > 0 {
            let knownCounts = self.overviewSpendKnownSubscriptionCounts(
                providers: spendProviders,
                model: spendModel)
            let spendSummary = OverviewSpendSummary(
                model: spendModel,
                providerCount: spendProviderCount,
                knownCostProviderCount: knownCounts.cost,
                knownTokenProviderCount: knownCounts.tokens)
            let summaryItem = self.makeMenuCardItem(
                OverviewSpendSummaryCardView(
                    summary: spendSummary,
                    days: spendModel.requestedDays,
                    width: menuWidth),
                id: "overviewSpendSummary",
                width: menuWidth,
                heightCacheScope: "overviewSpendSummary",
                heightCacheFingerprint: [
                    spendSummary.primarySpendText,
                    spendSummary.providerCoverageText,
                    spendSummary.tokenText ?? "",
                    spendSummary.historyCoverageText,
                    spendSummary.pricingCoverageText,
                    spendSummary.provenanceText,
                ].joined(separator: "|"))
            menu.addItem(summaryItem)
            if let shareItem = self.makeOverviewShareStatsMenuItem(model: spendModel) {
                menu.addItem(shareItem)
            }
            menu.addItem(.separator())
        }

        for (index, row) in rows.enumerated() {
            let instanceID = row.provider
            if index > 0 { menu.addItem(.separator()) }
            let identifier = "\(Self.overviewRowIdentifierPrefix)\(row.id)"
            guard let provider = instanceID.firstPartyProvider,
                  let model = row.model
            else {
                continue
            }
            let storageText = row.accountID == nil ? self.store.storageFootprintText(for: provider) : nil
            let submenu = row.accountID == nil ? self.makeOverviewRowSubmenu(
                provider: provider,
                model: model,
                width: menuWidth) : nil
            let item = self.makeMenuCardItem(
                OverviewMenuCardRowView(
                    model: model,
                    storageText: storageText,
                    width: menuWidth,
                    layout: self.settings.mergedOverviewLayout),
                id: identifier,
                width: menuWidth,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: model.heightFingerprint(
                    section: "overview",
                    additional: [
                        UsageMenuCardView.Model.heightFingerprintField("storage", storageText),
                        "layout=\(self.settings.mergedOverviewLayout.rawValue)",
                    ]),
                submenu: submenu,
                containsInteractiveControls: model.containsInteractiveControls,
                usesGPUSelection: true,
                onClick: { [weak self, weak interactionMenu] in
                    guard let self, let interactionMenu else { return }
                    self.selectOverviewProvider(instanceID, menu: interactionMenu)
                })
            if submenu == nil {
                // Keep plain rows wired for keyboard activation and accessibility action paths.
                item.target = self
                item.action = #selector(self.selectOverviewProvider(_:))
            }
            menu.addItem(item)
        }
        return true
    }

    func overviewProviderScopes(
        enabledProviders: [UsageProvider]) -> (visible: [ProviderInstanceID], spend: [UsageProvider])
    {
        let visible = self.settings.reconcileMergedOverviewSelectedProviders(
            activeProviders: self.overviewProviderIDs(enabledProviders: enabledProviders))
        var seenSpendProviders = Set<UsageProvider>()
        let spend = enabledProviders.filter { provider in
            seenSpendProviders.insert(provider).inserted &&
                self.settings.costSummaryShowsInline(for: provider)
        }
        return (
            visible: visible,
            spend: spend)
    }

    private func addOverviewEmptyState(to menu: NSMenu, enabledProviders: [UsageProvider]) {
        let resolvedProviders = self.settings.resolvedMergedOverviewProviders(
            activeProviders: self.overviewProviderIDs(enabledProviders: enabledProviders),
            maxVisibleProviders: Self.maxOverviewProviders)
        let message = resolvedProviders.isEmpty
            ? L("No providers selected for Overview.")
            : L("No overview data available.")
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.representedObject = "overviewEmptyState"
        menu.addItem(item)
    }

    private func addMenuCards(to menu: NSMenu, context: MenuCardContext, captureMenu: NSMenu? = nil) -> Bool {
        // Eligible claude-swap rows take precedence over Claude token-account cards; otherwise
        // the stacked token-account branch below would return before rendering the adapter rows.
        if ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: context.currentProvider,
            accountCount: self.store.claudeSwapAccountSnapshots.count,
            showSingleAccount: self.settings.claudeSwapShowSingleAccount)
        {
            self.addClaudeSwapMenuCards(to: menu, captureMenu: captureMenu ?? menu, context: context)
            return false
        }

        if let tokenAccountDisplay = context.tokenAccountDisplay, tokenAccountDisplay.showAll {
            if self.addCompactTokenAccountMenuIfPlanned(
                display: tokenAccountDisplay,
                to: menu,
                captureMenu: captureMenu ?? menu,
                context: context)
            {
                return false
            }
            let accountSnapshots = tokenAccountDisplay.snapshots
            let cards = accountSnapshots.isEmpty
                ? []
                : accountSnapshots.compactMap { accountSnapshot in
                    self.store.tokenAccountMenuCardModel(
                        for: context.currentProvider,
                        accountSnapshot: accountSnapshot)
                }
            self.addStackedMenuCards(cards, to: menu, context: context)
            return false
        }

        guard let model = self.menuCardModel(for: context.selectedProvider) else { return false }
        let renderedModel = self.menuCardRefreshMonitor.model(for: model.provider, fallback: model)
        if context.submenuContext.hasSubmenuItems ||
            self.requiresSectionedMenuForProviderDerivedCost(provider: context.currentProvider)
        {
            self.addMenuCardSections(
                to: menu,
                model: model,
                layoutModel: renderedModel,
                width: context.menuWidth,
                hasCostHistory: context.submenuContext.hasCostHistory)
            return true
        }

        menu.addItem(self.makeMenuCardItem(
            UsageMenuCardView(model: model, layoutModel: renderedModel, width: context.menuWidth),
            id: "menuCard",
            width: context.menuWidth,
            heightCacheScope: context.currentProvider.rawValue,
            heightCacheFingerprint: renderedModel.heightFingerprint(section: "card"),
            containsInteractiveControls: true))
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            menu.addItem(.separator())
        }
        menu.addItem(.separator())
        return false
    }

    private func addSubmenuItemsIfNeeded(
        to menu: NSMenu,
        currentProvider: UsageProvider,
        context: MenuSubmenuContext,
        addedSectionedCard: Bool)
    {
        guard context.hasSubmenuItems else { return }
        if !addedSectionedCard {
            // Only show these when we actually have additional data.
            if context.hasCostHistory {
                _ = self.addCostHistorySubmenu(to: menu, provider: currentProvider)
            }
        }
        if menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
    }

    func addPrimaryMenuContent(
        to menu: NSMenu,
        context: MenuCardContext,
        switcherSelection: ProviderSwitcherSelection,
        captureMenu: NSMenu? = nil)
    {
        if switcherSelection == .overview {
            let enabledProviders = self.store.enabledFirstPartyProvidersForDisplay()
            if self.addOverviewRows(
                to: menu,
                enabledProviders: enabledProviders,
                menuWidth: context.menuWidth,
                captureMenu: captureMenu)
            {
                menu.addItem(.separator())
            } else {
                self.addOverviewEmptyState(to: menu, enabledProviders: enabledProviders)
                menu.addItem(.separator())
            }
        } else {
            let addedSectionedCard = self.addMenuCards(to: menu, context: context, captureMenu: captureMenu)
            self.addSubmenuItemsIfNeeded(
                to: menu,
                currentProvider: context.currentProvider,
                context: context.submenuContext,
                addedSectionedCard: addedSectionedCard)
            self.addUsageHistoryClusterIfNeeded(to: menu, context: context)
        }
    }

    func addActionableSections(
        _ sections: [MenuDescriptor.Section],
        to menu: NSMenu,
        width: CGFloat,
        provider: UsageProvider?,
        captureMenu: NSMenu? = nil)
    {
        let actionableSections = sections.filter { section in section.entries.contains(where: \ .isActionable) }
        for (index, section) in actionableSections.enumerated() {
            for entry in section.entries {
                switch entry {
                case let .text(text, style):
                    if style == .secondary {
                        menu.addItem(self.makeWrappedSecondaryTextItem(text: text, width: width))
                        continue
                    }
                    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    if style == .headline {
                        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
                    } else if style == .secondary {
                        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                        item.attributedTitle = NSAttributedString(
                            string: text,
                            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                    }
                    menu.addItem(item)
                case let .action(title, action):
                    if action == .refresh {
                        let item = self.makePersistentRefreshItem(
                            title: L(title),
                            menu: captureMenu ?? menu,
                            width: width)
                        menu.addItem(item)
                        self.persistentRefreshItems.add(item)
                        continue
                    }
                    let localizedTitle = L(title)
                    if case let .focusAgentSession(session, remoteHost) = action {
                        menu.addItem(self.makeAgentSessionMenuItem(
                            title: localizedTitle,
                            session: session,
                            remoteHost: remoteHost,
                            width: width))
                        continue
                    }
                    let (selector, represented) = self.selector(for: action)
                    let item = NSMenuItem(title: localizedTitle, action: selector, keyEquivalent: "")
                    item.target = self
                    item.representedObject = represented
                    if let shortcut = self.shortcut(for: action) {
                        item.keyEquivalent = shortcut.key
                        item.keyEquivalentModifierMask = shortcut.modifiers
                    }
                    if let iconName = action.systemImageName,
                       let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
                    {
                        image.isTemplate = true
                        image.size = NSSize(width: 16, height: 16)
                        item.image = image
                    }
                    self.attachStatusComponentsSubmenuIfNeeded(
                        to: item,
                        action: action,
                        provider: provider,
                        width: width)
                    if case let .switchAccount(targetProvider) = action,
                       let subtitle = self.switchAccountSubtitle(for: targetProvider)
                    {
                        item.isEnabled = false
                        self.applySubtitle(subtitle, to: item, title: localizedTitle)
                    }
                    menu.addItem(item)
                case let .unavailable(title, tooltip):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    item.toolTip = tooltip
                    menu.addItem(item)
                case let .submenu(title, systemImageName, submenuItems):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    if let systemImageName,
                       let image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil)
                    {
                        image.isTemplate = true
                        image.size = NSSize(width: 16, height: 16)
                        item.image = image
                    }
                    let submenu = NSMenu(title: title)
                    submenu.autoenablesItems = false
                    for submenuItem in submenuItems {
                        let child = NSMenuItem(title: submenuItem.title, action: nil, keyEquivalent: "")
                        child.state = submenuItem.isChecked ? .on : .off
                        child.isEnabled = submenuItem.isEnabled
                        if let action = submenuItem.action {
                            let (selector, represented) = self.selector(for: action)
                            child.action = selector
                            child.target = self
                            child.representedObject = represented
                        }
                        submenu.addItem(child)
                    }
                    item.submenu = submenu
                    menu.addItem(item)
                case .divider:
                    menu.addItem(.separator())
                }
            }
            if index < actionableSections.count - 1 {
                menu.addItem(.separator())
            }
        }
    }

    func makeMenu(for provider: UsageProvider?) -> NSMenu {
        let menu = self.makeBaseMenu()
        if let provider {
            self.menuProviders[ObjectIdentifier(menu)] = provider.instanceID
        }
        return menu
    }

    private func makeBaseMenu() -> NSMenu {
        if self.menuAppearanceObserver == nil, !self.hasPreparedForAppShutdown {
            self.menuAppearanceObserver = StatusMenuAppearanceObserver(controller: self)
        }
        let menu = StatusItemMenu()
        menu.switcherShortcuts = { [weak self] in self?.settings.providerSwitcherShortcuts
            ?? ProviderSwitcherShortcuts.defaults
        }
        menu.autoenablesItems = false
        menu.delegate = self
        menu.persistentActionDelegate = self
        StatusMenuAppearance.pin(menu)
        return menu
    }

    private func makeProviderSwitcherItem(
        providers: [UsageProvider],
        includesOverview: Bool,
        selected: ProviderSwitcherSelection,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = ProviderSwitcherView(
            providers: providers,
            selected: selected,
            includesOverview: includesOverview,
            width: width,
            showsIcons: self.settings.switcherShowsIcons,
            iconProvider: { [weak self] provider in
                self?.switcherIcon(for: provider) ?? NSImage()
            },
            weeklyRemainingProvider: { [weak self] provider in
                self?.switcherWeeklyRemaining(for: provider)
            },
            onSelect: { [weak self, weak menu] selection in
                guard let self, let menu else { return }
                MenuSwitchFlickerProbe.debugLog("onSelect \(selection)")
                var provider: UsageProvider?
                self.preservingMergedSwitcherContentCachesDuringInvalidation {
                    switch selection {
                    case .overview:
                        self.settings.mergedMenuLastSelectedWasOverview = true
                        provider = self.resolvedMenuProvider()
                    case let .provider(selectedProvider):
                        self.settings.mergedMenuLastSelectedWasOverview = false
                        self.selectedMenuProvider = selectedProvider
                        provider = selectedProvider.firstPartyProvider
                    }
                    switch selection {
                    case .overview:
                        // Provider-specific by design: Codex is the persisted fallback for an empty overview.
                        self.lastMenuProvider = (provider ?? .claude).instanceID
                    case let .provider(provider):
                        self.lastMenuProvider = provider
                    }
                    self.lastMergedSwitcherSelection = selection
                    self.refreshProviderSelectionDependentUI(deferRendering: true)
                }
                self.requestProviderSwitcherMenuRebuild(menu, provider: provider)
            })
        let item = NSMenuItem()
        item.title = ""
        item.view = view
        item.isEnabled = false
        return item
    }

    private func makeTokenAccountSwitcherItem(
        display: TokenAccountMenuDisplay,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = TokenAccountSwitcherView(
            accounts: display.accounts,
            selectedIndex: display.activeIndex,
            width: width,
            onSelect: { [weak self, weak menu] index -> Task<Void, Never>? in
                guard let self, let menu else { return nil }
                guard display.accounts.indices.contains(index) else { return nil }
                let selectedAccount = display.accounts[index]
                self.advanceMenuInteraction(for: menu)
                self.settings.setActiveTokenAccountIndex(index, for: display.provider)
                self.store.activateCachedTokenAccountSnapshot(
                    provider: display.provider,
                    accountID: selectedAccount.id)
                self.applyIcon(phase: nil)
                self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: display.provider)
                return Task { @MainActor [weak self, weak menu] in
                    guard let self else { return }
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(display.provider)
                    }
                    guard let menu else { return }
                    self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: display.provider)
                }
            })
        let item = NSMenuItem()
        item.title = ""
        item.view = view
        item.isEnabled = false
        return item
    }

    func resolvedMenuProvider(enabledProviders: [UsageProvider]? = nil) -> UsageProvider? {
        let enabled = enabledProviders ?? self.store.enabledFirstPartyProvidersForDisplay()
        if enabled.isEmpty {
            return .claude
        }
        if let selected = self.selectedMenuProvider?.firstPartyProvider, enabled.contains(selected) {
            return selected
        }
        // Prefer an available provider so the default menu content matches the status icon.
        // Falls back to first display provider when all lack credentials.
        return enabled.first(where: self.isEnabled) ?? enabled.first
    }

    func menuProvider(for menu: NSMenu) -> UsageProvider? {
        if self.shouldMergeIcons {
            return self.resolvedMenuProvider()
        }
        if let provider = self.menuProviders[ObjectIdentifier(menu)] {
            return provider.firstPartyProvider
        }
        if menu === self.fallbackMenu {
            return nil
        }
        return self.store.enabledFirstPartyProvidersForDisplay().first ?? .claude
    }

    private func scheduleOpenMenuRefresh(for menu: NSMenu) {
        // Queue refresh work only when visible menu data is missing or stale. Here "stale" means the last
        // provider fetch failed and needs a retry; periodic freshness is handled by the refresh timer.
        // AppKit menu tracking is modal, so starting provider refreshes while it is active can make the menu
        // feel frozen and can block keyboard focus from returning.
        // Exception: when `refreshAllProvidersOnMenuOpen` is enabled, every enabled provider is refreshed on
        // open regardless of freshness — still after the delay below, and still via the light usage-only
        // primitive. Token cost is not part of that primitive, so the plan also schedules a forced cost rescan
        // (fire-and-forget; the
        // open menu picks up the published snapshot through the store observation).
        let providersNeedingRetryAtOpen = self.delayedRefreshRetryProviders(for: menu).filter {
            self.store.needsUsageRefreshRetry(for: $0)
        }
        if !providersNeedingRetryAtOpen.isEmpty {
            self.deferMenuInteractionRefreshIfNeeded(providers: providersNeedingRetryAtOpen)
        }
        let key = ObjectIdentifier(menu)
        self.menuRefreshTasks[key]?.cancel()
        self.menuRefreshTasks[key] = Task { @MainActor [weak self, weak menu] in
            guard let self, let menu else { return }
            try? await Task.sleep(for: Self.menuOpenRefreshDelay)
            guard !Task.isCancelled else { return }
            guard self.isMenuRefreshEnabled else { return }
            #if DEBUG
            self.onDelayedMenuRefreshAttemptForTesting?()
            #endif
            guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
            let refreshAllOnOpen = self.settings.refreshAllProvidersOnMenuOpen
            let enabledProviders = self.store.enabledProvidersForBackgroundWork()
            let visibleProviders = self.delayedRefreshRetryProviders(for: menu)
            let visibleInstanceIDs = visibleProviders.map(\.instanceID)
            let plan = MenuOpenRefreshPlan.resolve(.init(
                refreshAllOnOpen: refreshAllOnOpen,
                enabledProviders: enabledProviders,
                visibleProviders: visibleInstanceIDs,
                refreshingProviders: self.store.refreshingProviders,
                staleProviders: Set(visibleProviders.filter { self.store.isStale(provider: $0) }.map(\.instanceID)),
                missingProviders: Set(visibleProviders
                    .filter { !self.store.hasSatisfiedUsageFetch(for: $0) }
                    .map(\.instanceID))))
            if plan.refreshTokenCost {
                self.store.scheduleForcedTokenRefresh()
            }
            let retryInstanceIDs = plan.providers
            let retryProviders = retryInstanceIDs.compactMap(\.firstPartyProvider)
            guard !retryInstanceIDs.isEmpty else {
                self.clearSatisfiedDeferredMenuInteractionRefreshes(
                    for: self.delayedRefreshRetryProviders(for: menu).map(\.instanceID))
                // Ordinary store changes intentionally stay queued until the next open. Rebuilding here
                // made first-open work such as the storage scan flash the visible menu after 1.2 seconds.
                if !providersNeedingRetryAtOpen.isEmpty, self.menuNeedsRefresh(menu) {
                    self.scheduleOpenMenuRebuildIfStillVisible(
                        menu,
                        provider: self.menuProvider(for: menu),
                        resyncReadinessBaselineAfterRebuild: self.openMenus.count == 1)
                }
                return
            }
            self.deferredMenuInteractionRefreshProviders.formUnion(retryInstanceIDs)
            await ProviderInteractionContext.$current.withValue(.background) {
                if plan.scheduling == .concurrent {
                    // Refresh concurrently so one slow provider doesn't delay the rest, mirroring the
                    // periodic refresh in `UsageStore.runRefresh`. `coalesceIfRefreshing` makes each call
                    // wait for any in-flight refresh (e.g. a manual refresh) instead of overriding it.
                    await withTaskGroup(of: Void.self) { group in
                        for provider in retryProviders {
                            group.addTask {
                                await self.store.refreshProvider(provider, coalesceIfRefreshing: true)
                            }
                        }
                    }
                } else {
                    for provider in retryProviders {
                        guard !Task.isCancelled else { return }
                        await self.store.refreshProvider(provider, coalesceIfRefreshing: true)
                    }
                }
            }
            let stillNeedsRetry = retryProviders.contains {
                self.store.needsUsageRefreshRetry(for: $0)
            }
            if !stillNeedsRetry {
                self.clearSatisfiedDeferredMenuInteractionRefreshes(for: retryInstanceIDs)
            }
            guard !Task.isCancelled else { return }
            guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
            self.invalidateMenus(
                refreshOpenMenus: true,
                deferOpenParentMenuRebuild: false,
                allowStaleContentDuringDataRefresh: true)
        }
    }

    private func delayedRefreshRetryProviders(for menu: NSMenu) -> [UsageProvider] {
        self.renderedProviders(for: menu)
    }

    func renderedProviders(for menu: NSMenu) -> [UsageProvider] {
        let enabledProviders = self.store.enabledFirstPartyProvidersForDisplay()
        guard !enabledProviders.isEmpty else { return [] }
        let includesOverview = self.includesOverviewTab(enabledProviders: enabledProviders)
        let selection = self.resolvedSwitcherSelection(
            enabledProviders: enabledProviders,
            includesOverview: includesOverview)
        let switcherProviderCount = self.switcherProviderIDs(enabledFirstPartyProviders: enabledProviders).count

        if self.shouldMergeIcons,
           switcherProviderCount > 1,
           selection == .overview
        {
            return self.settings.resolvedMergedOverviewProviders(
                activeProviders: self.overviewProviderIDs(enabledProviders: enabledProviders),
                maxVisibleProviders: Self.maxOverviewProviders).compactMap(\.firstPartyProvider)
        }

        if let provider = self.menuProvider(for: menu)
            ?? self.resolvedMenuProvider(enabledProviders: enabledProviders)
        {
            return [provider]
        }
        return enabledProviders
    }

    private func addMenuCardSections(
        to menu: NSMenu,
        model: UsageMenuCardView.Model,
        layoutModel: UsageMenuCardView.Model,
        width: CGFloat,
        hasCostHistory: Bool)
    {
        let provider = layoutModel.provider
        let hasCredits = layoutModel.creditsText != nil
        let hasExtraUsage = layoutModel.providerCost != nil
        let hasCost = layoutModel.tokenUsage != nil
        let bottomPadding = CGFloat(hasCredits ? 4 : 6)
        let sectionSpacing = CGFloat(6)
        let creditsBottomPadding = bottomPadding
        func addSectionSeparator() {
            guard menu.items.last?.isSeparatorItem != true else { return }
            menu.addItem(.separator())
        }

        if layoutModel.hasUsageContent {
            let usageView = UsageMenuCardHeaderAndUsageSectionView(
                model: model,
                layoutModel: layoutModel,
                bottomPadding: bottomPadding,
                width: width)
            let usageSubmenu = self.makeUsageSubmenu(
                provider: provider,
                hasInlineCostDashboard: layoutModel.inlineUsageDashboard != nil,
                width: width)
            menu.addItem(self.makeMenuCardItem(
                usageView,
                id: "menuCardUsage",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: layoutModel.heightFingerprint(section: "usage"),
                submenu: usageSubmenu,
                containsInteractiveControls: true))
        } else {
            let headerView = UsageMenuCardHeaderSectionView(
                model: layoutModel,
                showDivider: false,
                width: width)
            menu.addItem(self.makeMenuCardItem(
                headerView,
                id: "menuCardHeader",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: layoutModel.heightFingerprint(section: "header"),
                containsInteractiveControls: true))
        }

        if self.addStorageMenuCardSection(to: menu, provider: provider, width: width),
           hasCredits || hasExtraUsage
        {
            addSectionSeparator()
        }

        if hasCredits {
            addSectionSeparator()
            let creditsView = UsageMenuCardCreditsSectionView(
                model: model,
                showBottomDivider: false,
                topPadding: sectionSpacing,
                bottomPadding: creditsBottomPadding,
                width: width)
            menu.addItem(self.makeMenuCardItem(
                creditsView,
                id: "menuCardCredits",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: layoutModel.heightFingerprint(section: "credits")))
        }
        if hasExtraUsage {
            addSectionSeparator()
            let extraUsageSubmenu: NSMenu? = nil
            let extraUsageView = UsageMenuCardExtraUsageSectionView(
                model: model,
                topPadding: sectionSpacing,
                bottomPadding: bottomPadding,
                width: width)
            menu.addItem(self.makeMenuCardItem(
                extraUsageView,
                id: "menuCardExtraUsage",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: layoutModel.heightFingerprint(section: "extraUsage"),
                submenu: extraUsageSubmenu))
        }
        if hasCost {
            addSectionSeparator()
            let costSubmenu = hasCostHistory ? self
                .makeCostHistorySubmenu(provider: provider, width: width) : nil
            menu.addItem(self.makeCostMenuCardItem(
                model: model,
                submenu: costSubmenu,
                width: width))
        }
    }

    private func switcherIcon(for provider: UsageProvider) -> NSImage {
        if let brand = ProviderBrandIcon.image(for: provider) {
            return brand
        }

        // Fallback to the dynamic icon renderer if resources are missing (e.g. dev bundle mismatch).
        let snapshot = self.store.snapshot(for: provider.instanceID)
        let showUsed = self.settings.usageBarsShowUsed
        let style = self.store.style(for: provider)
        let now = Date()
        let resolved = snapshot.map {
            IconRemainingResolver.resolvedPercents(
                snapshot: $0,
                style: style,
                showUsed: showUsed,
                secondaryOverrideWindowID: nil,
                now: now)
        }
        let primary = resolved?.primary
        let weekly = resolved?.secondary
        let stale = self.store.isStale(provider: provider)
        let indicator = self.store.statusIndicator(for: provider)
        let image = IconRenderer.makeIcon(
            primaryRemaining: primary,
            weeklyRemaining: weekly,
            creditsRemaining: nil,
            stale: stale,
            style: style,
            blink: 0,
            wiggle: 0,
            tilt: 0,
            statusIndicator: indicator,
            hideCritters: self.settings.menuBarHidesCritters,
            quotaLayoutPolicy: .provider(provider, snapshot: snapshot))
        image.isTemplate = true
        return image
    }

    @discardableResult
    private func addCostHistorySubmenu(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard let submenu = self.makeCostHistorySubmenu(provider: provider, width: self.renderedMenuWidth(for: menu))
        else { return false }
        let title: String = switch self.store.settings.costReportingPeriod {
        case .rolling(1): L("Usage history (today)")
        case let .rolling(days): String(format: L("Usage history (%d days)"), days)
        case let period: "\(L("cost_history_window_title")) (\(L(period.label)))"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    private func makeUsageSubmenu(
        provider: UsageProvider,
        hasInlineCostDashboard: Bool,
        width: CGFloat? = nil) -> NSMenu?
    {
        if hasInlineCostDashboard, self.settings.costSummaryShowsSubmenu(for: provider) {
            return self.makeCostHistorySubmenu(provider: provider, width: width)
        }
        return nil
    }

    func makeCostHistorySubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else { return nil }
        guard self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(
                chartID: Self.costHistoryChartID,
                provider: provider,
                width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.costHistoryChartID, provider: provider)
    }

    func tokenSnapshotForCostHistorySubmenu(provider: UsageProvider) -> CostUsageTokenSnapshot? {
        let projected = self.store.tokenSnapshot(
            fromProviderSnapshot: self.store.snapshot(for: provider.instanceID),
            provider: provider)
        if UsageStore.tokenCostRequiresProviderSnapshot(provider) {
            return projected
        }
        return projected ?? self.store.tokenSnapshot(for: provider)
    }

    /// Unlike `makeUsageSubmenu`'s and `tokenCostMenuSectionEnabled`'s provider checks, this one
    /// intentionally reuses `tokenCostRequiresProviderSnapshot`: any provider whose cost is
    /// sourced by projecting a snapshot field (rather than the CostUsageFetcher pipeline) can only
    /// render that cost through `addMenuCardSections`'s sectioned layout, so the two concepts are
    /// genuinely coupled here, not coincidentally aliased. The name is deliberately broader than
    /// "top-pane submenu" — opencodego satisfies this via its collapsible "Cost" row, not a
    /// provider-native top-pane submenu like openai/mistral.
    private func requiresSectionedMenuForProviderDerivedCost(provider: UsageProvider) -> Bool {
        UsageStore.tokenCostRequiresProviderSnapshot(provider) &&
            self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false
    }

    func makeStorageBreakdownSubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard self.store.storageFootprint(for: provider)?.components.isEmpty == false else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(
                chartID: Self.storageBreakdownID,
                provider: provider,
                width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.storageBreakdownID, provider: provider)
    }

    /// Providers that surface the live component list as a native submenu. Every other provider
    /// keeps the plain "Status Page" link that opens the website. Kept deliberately small: these
    /// are the statuspage.io/incident.io feeds we actively curate and trust to render well.
    /// Provider-specific by design: these four curated status feeds expose component trees rendered by the app.
    static let statusComponentsSubmenuProviders: Set<UsageProvider> = [.claude]

    /// Filters `components` down to a provider's descriptor-owned named allowlist, if configured;
    /// returns `components` unchanged when the provider has no allowlist. Matching is by exact
    /// `name` equality at the top level only (groups and leaves alike).
    static func filterStatusComponents(
        _ components: [ProviderStatusComponent],
        for provider: UsageProvider) -> [ProviderStatusComponent]
    {
        let metadata = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        guard let allowlist = metadata.statusComponentAllowlist else { return components }
        return components.filter { allowlist.contains($0.name) }
    }

    /// Builds the status submenu (component rows + a website link) for the curated providers in
    /// `statusComponentsSubmenuProviders`. Gated on the provider being in that allowlist (and
    /// having a component feed) rather than on components being loaded yet: status is fetched
    /// asynchronously, so gating on loaded components would leave the row as a plain link for any
    /// provider whose first fetch hasn't landed at menu-build time. The submenu hydrates from the
    /// live component list each time it opens (and shows just the website link until the first
    /// fetch lands). Returns nil for all other providers, which keep the plain status-page link.
    /// For curated providers, turns the "Status Page" row into a submenu of live component
    /// statuses instead of a direct website link (the link moves to the bottom of the submenu).
    func attachStatusComponentsSubmenuIfNeeded(
        to item: NSMenuItem,
        action: MenuDescriptor.MenuAction,
        provider: UsageProvider?,
        width: CGFloat)
    {
        guard action == .statusPage,
              let provider,
              let submenu = self.makeStatusComponentsSubmenu(provider: provider, width: width)
        else { return }
        item.action = nil
        item.submenu = submenu
    }

    func makeStatusComponentsSubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard self.store.statusChecksEnabled else { return nil }
        guard Self.statusComponentsSubmenuProviders.contains(provider) else { return nil }
        guard ProviderDescriptorRegistry.descriptor(for: provider).metadata.statusPageURL != nil else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(
                chartID: Self.statusComponentsID,
                provider: provider,
                width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.statusComponentsID, provider: provider)
    }

    @objc func menuCardNoOp(_ sender: NSMenuItem) {
        _ = sender
    }
}
