import AppKit
import BarsCore
import Testing
@testable import Bars

@Suite(.serialized)
@MainActor
struct StatusItemBalanceDisplayTests {
    @Test
    func `menu bar display text uses zen balance when open code has no subscription`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-opencodego-zen-only",
            provider: .opencodego)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 23.75,
                limit: 0,
                currencyCode: "USD",
                period: "Zen balance",
                updatedAt: Date()),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .opencodego)
        store._setErrorForTesting(nil, provider: .opencodego)

        let displayText = controller.menuBarDisplayText(for: .opencodego, snapshot: snapshot)

        #expect(displayText == "$23.75")
    }

    @Test
    func `menu bar display text uses negative zen balance when open code is in deficit`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-opencodego-zen-deficit",
            provider: .opencodego)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: -4.25,
                limit: 0,
                currencyCode: "USD",
                period: "Zen balance",
                updatedAt: Date()),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .opencodego)
        store._setErrorForTesting(nil, provider: .opencodego)

        let displayText = controller.menuBarDisplayText(for: .opencodego, snapshot: snapshot)

        #expect(displayText == "-$4.25")
    }

    @Test
    func `menu bar display text prefers the most constrained open code subscription quota to zen balance`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-opencodego-subscription",
            provider: .opencodego)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 34, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            providerCost: ProviderCostSnapshot(
                used: 23.75,
                limit: 0,
                currencyCode: "USD",
                period: "Zen balance",
                updatedAt: Date()),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .opencodego)
        store._setErrorForTesting(nil, provider: .opencodego)

        let displayText = controller.menuBarDisplayText(for: .opencodego, snapshot: snapshot)

        #expect(displayText == "34%")
    }

    @Test
    func `menu bar display text uses deepseek balance`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-deepseek-balance",
            provider: .deepseek)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$9.32 (Paid: $9.32 / Granted: $0.00)"),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .deepseek)
        store._setErrorForTesting(nil, provider: .deepseek)

        let displayText = controller.menuBarDisplayText(for: .deepseek, snapshot: snapshot)

        #expect(displayText == "$9.32")
    }

    @Test(arguments: [MenuBarLayoutToken.resetCountdown, .resetAbsolute])
    func `custom DeepSeek menu bar layouts use compact balance in status item and preview`(
        token: MenuBarLayoutToken)
    {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-deepseek-custom-layout",
            provider: .deepseek)
        let layout = MenuBarLayout(lines: [[token]])
        settings.setMenuBarLayout(layout, for: nil)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "¥2.23 (Paid: ¥2.23 / Granted: ¥0.00)"),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .deepseek)
        store._setErrorForTesting(nil, provider: .deepseek)

        let statusItemData = controller.menuBarLayoutRenderData(
            provider: .deepseek,
            snapshot: snapshot,
            warningFlash: false)
        let previewData = MenuBarLayoutPreview(
            layout: layout,
            provider: .deepseek,
            settings: settings,
            store: store)
            .liveData(provider: .deepseek, snapshot: snapshot)

        for data in [statusItemData, previewData] {
            let rendered = MenuBarLayoutRenderer().render(
                layout: layout,
                data: data,
                icon: nil,
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: true,
                    conditionals: [],
                    appearanceName: "aqua",
                    isDebugApp: false,
                    now: Date()))

            #expect(data.automatic?.resetDescription == "¥2.23")
            #expect(rendered.attributedTitle.string == "¥2.23")
        }
    }

    @Test
    func `button title spacing only applies when image is present`() {
        #expect(StatusItemController.buttonTitle("42%", hasImage: true) == " 42%")
        #expect(StatusItemController.buttonTitle("42%", hasImage: false) == "42%")
        #expect(StatusItemController.buttonTitle(nil, hasImage: true).isEmpty)
        #expect(StatusItemController.buttonTitle("", hasImage: true).isEmpty)
    }

    @Test
    func `debug button title stays visible with or without a usage value`() {
        #expect(StatusItemController.buttonTitle(nil, hasImage: true, isDebugApp: true) == " D")
        #expect(StatusItemController.buttonTitle("42%", hasImage: true, isDebugApp: true) == " 42% D")
        #expect(StatusItemController.buttonTitle("42%", hasImage: false, isDebugApp: true) == "42% D")
    }

    @Test
    func `high contrast button title embeds image and metric in attributed content`() throws {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true

        let title = StatusItemController.highContrastButtonTitle(image: image, title: " 42%")

        #expect(title.string == "\u{FFFC} 42%")
        let attachment = try #require(title.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.image === image)
        #expect(attachment.bounds.width == 18)
        #expect(attachment.bounds.height == 18)
        #expect(title.attribute(.font, at: 1, effectiveRange: nil) is NSFont)
        #expect(title.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == .labelColor)
    }

    @Test
    func `debug bundle identity updates status item accessibility`() {
        #expect(StatusItemController.isDebugApp(bundleIdentifier: "com.sirrayi.bars.debug"))
        #expect(!StatusItemController.isDebugApp(bundleIdentifier: "com.sirrayi.bars"))
        #expect(!StatusItemController.isDebugApp(bundleIdentifier: nil))
        #expect(StatusItemController.statusItemAccessibilityTitle(isDebugApp: true) == "bars Debug")
        #expect(StatusItemController.statusItemAccessibilityTitle(isDebugApp: false) == "bars")
    }

    func makeSettings(suiteName: String, provider: UsageProvider) -> SettingsStore {
        let settings = testSettingsStore(suiteName: suiteName, userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = provider.instanceID
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = true

        let registry = ProviderRegistry.shared
        if let metadata = registry.metadata[provider] {
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: true)
        }
        return settings
    }

    func makeStoreAndController(settings: SettingsStore) -> (UsageStore, StatusItemController) {
        let store = UsageStore(browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (store, controller)
    }
}

extension StatusItemBalanceDisplayTests {
    @Test(arguments: [false, true])
    func `stored DeepSeek icon and percent layout shows balance in status item and preview`(showUsed: Bool) {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-deepseek-layout-balance",
            provider: .deepseek)
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        settings.setMenuBarLayout(layout, for: nil)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "CNY",
            totalBalance: 100,
            grantedBalance: 0,
            toppedUpBalance: 100,
            updatedAt: Date()).toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .deepseek)
        store._setErrorForTesting(nil, provider: .deepseek)

        let statusItemData = controller.menuBarLayoutRenderData(
            provider: .deepseek,
            snapshot: snapshot,
            warningFlash: false)
        let previewData = MenuBarLayoutPreview(
            layout: layout,
            provider: .deepseek,
            settings: settings,
            store: store)
            .liveData(provider: .deepseek, snapshot: snapshot)

        for data in [statusItemData, previewData] {
            let rendered = MenuBarLayoutRenderer().render(
                layout: layout,
                data: data,
                icon: NSImage(size: NSSize(width: 16, height: 16)),
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: showUsed,
                    conditionals: [],
                    appearanceName: "aqua",
                    isDebugApp: false,
                    now: Date()))

            #expect(data.automaticText == "¥100.00")
            #expect(rendered.attributedTitle.string.hasSuffix("¥100.00"))
            #expect(rendered.accessibilityLabel.contains("¥100.00"))
        }
    }

    @Test
    func `balance reset fallbacks render once beside automatic balance and remain in reset only layouts`() {
        let settings = self.makeSettings(suiteName: "StatusItemBalanceDisplayTests-balance-reset", provider: .deepseek)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "CNY",
            totalBalance: 100,
            grantedBalance: 0,
            toppedUpBalance: 100,
            updatedAt: Date()).toUsageSnapshot()
        store._setSnapshotForTesting(snapshot, provider: .deepseek)
        for lines: [[MenuBarLayoutToken]] in [
            [[.percent(window: .automatic), .separatorDot, .resetCountdown]],
            [[.resetAbsolute, .separatorDot, .percent(window: .automatic)]],
            [[.percent(window: .automatic)], [.resetCountdown]],
            [[.resetCountdown]],
            [[.resetAbsolute]],
        ] {
            let layout = MenuBarLayout(lines: lines)
            settings.setMenuBarLayout(layout, for: nil)
            let statusData = controller.menuBarLayoutRenderData(
                provider: .deepseek, snapshot: snapshot, warningFlash: false)
            let previewData = MenuBarLayoutPreview(
                layout: layout, provider: .deepseek, settings: settings, store: store)
                .liveData(provider: .deepseek, snapshot: snapshot)
            for data in [statusData, previewData] {
                let rendered = MenuBarLayoutRenderer().render(
                    layout: layout,
                    data: data,
                    icon: nil,
                    options: MenuBarLayoutRenderOptions(
                        size: .regular,
                        highContrast: false,
                        showUsed: false,
                        conditionals: [],
                        appearanceName: "aqua",
                        isDebugApp: false,
                        now: Date()))
                #expect(rendered.attributedTitle.string == "¥100.00")
                #expect(rendered.accessibilityLabel.components(separatedBy: "¥100.00").count == 2)
            }
        }
    }

    @Test
    func `stored DeepSeek icon and percent layout shows zero balance instead of percent`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-deepseek-layout-zero-balance",
            provider: .deepseek)
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        settings.setMenuBarLayout(layout, for: nil)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = DeepSeekUsageSnapshot(
            isAvailable: false,
            currency: "USD",
            totalBalance: 0,
            grantedBalance: 0,
            toppedUpBalance: 0,
            updatedAt: Date()).toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .deepseek)
        store._setErrorForTesting(nil, provider: .deepseek)

        let statusItemData = controller.menuBarLayoutRenderData(
            provider: .deepseek,
            snapshot: snapshot,
            warningFlash: false)

        let rendered = MenuBarLayoutRenderer().render(
            layout: layout,
            data: statusItemData,
            icon: NSImage(size: NSSize(width: 16, height: 16)),
            options: MenuBarLayoutRenderOptions(
                size: .regular,
                highContrast: false,
                showUsed: true,
                conditionals: [],
                appearanceName: "aqua",
                isDebugApp: false,
                now: Date()))

        #expect(statusItemData.automaticText == "$0.00")
        #expect(rendered.attributedTitle.string.hasSuffix("$0.00"))
    }

    @Test
    func `stored OpenCode Go zen-only layout shows balance in status item and preview`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-opencodego-layout-zen-balance",
            provider: .opencodego)
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        settings.setMenuBarLayout(layout, for: nil)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = OpenCodeGoUsageSnapshot(
            isBalanceOnly: true,
            hasMonthlyUsage: false,
            rollingUsagePercent: 0,
            weeklyUsagePercent: 0,
            monthlyUsagePercent: 0,
            rollingResetInSec: 0,
            weeklyResetInSec: 0,
            monthlyResetInSec: 0,
            zenBalanceUSD: 25,
            updatedAt: Date()).toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .opencodego)
        store._setErrorForTesting(nil, provider: .opencodego)

        let statusItemData = controller.menuBarLayoutRenderData(
            provider: .opencodego,
            snapshot: snapshot,
            warningFlash: false)
        let previewData = MenuBarLayoutPreview(
            layout: layout,
            provider: .opencodego,
            settings: settings,
            store: store)
            .liveData(provider: .opencodego, snapshot: snapshot)

        for data in [statusItemData, previewData] {
            let rendered = MenuBarLayoutRenderer().render(
                layout: layout,
                data: data,
                icon: NSImage(size: NSSize(width: 16, height: 16)),
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: true,
                    conditionals: [],
                    appearanceName: "aqua",
                    isDebugApp: false,
                    now: Date()))

            #expect(data.automatic == nil)
            #expect(data.automaticText == "$25.00")
            #expect(rendered.attributedTitle.string.hasSuffix("$25.00"))
        }
    }
}

extension StatusItemBalanceDisplayTests {}
