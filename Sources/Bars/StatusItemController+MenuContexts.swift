import AppKit
import BarsCore

extension StatusItemController {
    struct MenuSubmenuContext {
        let hasCostHistory: Bool
        let hasSubmenuItems: Bool
    }

    struct MenuCardContext {
        let currentProvider: UsageProvider
        let selectedProvider: UsageProvider?
        let menuWidth: CGFloat
        let tokenAccountDisplay: TokenAccountMenuDisplay?
        let submenuContext: MenuSubmenuContext
    }

    struct MenuRebuildContext {
        let enabledProviders: [UsageProvider]
        let includesOverview: Bool
        let switcherSelection: ProviderSwitcherSelection?
        let currentProvider: UsageProvider
        let selectedProvider: UsageProvider?
        let menuWidth: CGFloat
        let tokenAccountDisplay: TokenAccountMenuDisplay?
        let submenuContext: MenuSubmenuContext
        let descriptor: MenuDescriptor
    }
}
