import AppKit
import BarsCore

extension StatusItemController {
    func isPersistentRefreshItem(_ item: NSMenuItem) -> Bool {
        item.representedObject as? String == Self.persistentRefreshMenuItemID
    }

    func makePersistentRefreshItem(title: String, menu: NSMenu, width: CGFloat) -> NSMenuItem {
        let shortcutText = self.shortcut(for: .refresh).map(Self.shortcutDisplayLabel)
        let metrics = MenuActionRowMetrics.defaults
        let view = MenuActionRowView(
            title: title,
            systemImageName: nil,
            shortcutText: shortcutText,
            onClick: { [weak self, weak menu] in
                guard let self, let menu else { return }
                if let menu = menu as? StatusItemMenu {
                    menu.requestPersistentRefreshAction()
                } else {
                    self.performPersistentRefreshAction(in: ObjectIdentifier(menu))
                }
            })
        let enabled = !self.isRefreshActionInFlight(for: menu)
        view.setEnabled(enabled)
        view.applySize(width: width, height: metrics.rowHeight)

        let item = NSMenuItem()
        item.title = title
        item.representedObject = Self.persistentRefreshMenuItemID
        item.view = view
        item.isEnabled = enabled
        item.keyEquivalentModifierMask = []
        // No toolTip: the row already reads "Refresh" with its shortcut badge, and
        // during tab switches the churn under a stationary cursor makes AppKit pop
        // the tooltip instantly — a stray floating "Refresh" box beside the menu.
        return item
    }

    /// Builds an action row with the shared neutral hover. The item keeps its target, action, and key
    /// equivalent so keyboard activation and shortcuts stay native; pointer clicks run through the view.
    /// A row with a submenu shows a chevron and lets AppKit open the submenu instead of running the action.
    func makeActionRowItem(
        title: String,
        action: MenuDescriptor.MenuAction,
        provider: UsageProvider?,
        width: CGFloat) -> NSMenuItem
    {
        let (selector, represented) = self.selector(for: action)
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        let shortcut = self.shortcut(for: action)
        if let shortcut {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
        self.attachStatusComponentsSubmenuIfNeeded(to: item, action: action, provider: provider, width: width)

        let hasSubmenu = item.submenu != nil
        // No leading symbol: the open menu never showed action icons, and the Refresh row has none.
        let view = MenuActionRowView(
            title: title,
            systemImageName: nil,
            shortcutText: hasSubmenu ? nil : shortcut.map(Self.shortcutDisplayLabel),
            showsSubmenuIndicator: hasSubmenu,
            onClick: hasSubmenu ? nil : { [weak self, weak item] in
                guard let self, let item else { return }
                item.menu?.cancelTracking()
                NSApp.sendAction(selector, to: self, from: item)
            })
        view.applySize(width: width, height: MenuActionRowMetrics.defaults.rowHeight)
        item.view = view
        return item
    }

    private static func shortcutDisplayLabel(
        for shortcut: (key: String, modifiers: NSEvent.ModifierFlags)) -> String
    {
        var label = ""
        if shortcut.modifiers.contains(.control) {
            label += "^"
        }
        if shortcut.modifiers.contains(.option) {
            label += "⌥"
        }
        if shortcut.modifiers.contains(.shift) {
            label += "⇧"
        }
        if shortcut.modifiers.contains(.command) {
            label += "⌘"
        }
        if !label.isEmpty {
            label += " "
        }
        return label + shortcut.key.uppercased()
    }
}
