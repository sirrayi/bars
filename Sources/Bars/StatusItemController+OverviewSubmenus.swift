import AppKit
import BarsCore

extension StatusItemController {
    @objc func selectOverviewProvider(_ sender: NSMenuItem) {
        guard let represented = sender.representedObject as? String,
              represented.hasPrefix(Self.overviewRowIdentifierPrefix)
        else {
            return
        }
        let rawProvider = String(represented.dropFirst(Self.overviewRowIdentifierPrefix.count))
        guard let provider = MergedOverviewRow.providerID(from: rawProvider),
              let menu = sender.menu
        else {
            return
        }

        self.selectOverviewProvider(provider, menu: menu)
    }

    func selectOverviewProvider(_ provider: ProviderInstanceID, menu: NSMenu) {
        if !self.settings.mergedMenuLastSelectedWasOverview, self.selectedMenuProvider == provider { return }
        self.preservingMergedSwitcherContentCachesDuringInvalidation {
            self.settings.mergedMenuLastSelectedWasOverview = false
            self.lastMergedSwitcherSelection = .provider(provider)
            self.selectedMenuProvider = provider
            self.lastMenuProvider = provider
            self.refreshProviderSelectionDependentUI(deferRendering: true)
        }
        // Custom-view clicks stay open and rebuild next turn. Standard menu-item activation can close;
        // menuWillOpen then renders the saved provider without doing structural work inside the action.
        self.requestProviderSwitcherMenuRebuild(menu, provider: provider.firstPartyProvider)
    }
}
