import AppKit
import BarsCore
import KeyboardShortcuts
import Observation
import QuartzCore
import Security
import SwiftUI

enum BarsLaunchMode: Equatable {
    case application
    case hookEvent

    static func resolve(arguments: [String]) -> Self {
        // Other bars installations can leave this app path registered in ~/.codex/hooks.json.
        // Treat those invocations as a no-op before AppKit creates a second set of status items.
        arguments.dropFirst().contains("--hook-event") ? .hookEvent : .application
    }
}

@main
enum BarsEntryPoint {
    @MainActor
    static func main() {
        // Packaging launch smoke check (#2738): force the resource loads that
        // trapped in 0.48.0 and exit before any AppKit/UI setup.
        if BarsCoreResourceSmoke.isRequested() {
            exit(BarsCoreResourceSmoke.run())
        }
        #if DEBUG
        if MenuBarLayoutNativeProof.runIfRequested() {
            return
        }
        #endif
        guard BarsLaunchMode.resolve(arguments: CommandLine.arguments) == .application else {
            return
        }
        TerminalLauncher().cleanUpAbandonedConfigs()
        BarsApp.main()
    }
}

struct BarsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: SettingsStore
    @State private var store: UsageStore
    private let preferencesSelection: PreferencesSelection

    init() {
        let env = ProcessInfo.processInfo.environment
        let storedLevel = BarsLog.parseLevel(UserDefaults.standard.string(forKey: "debugLogLevel")) ?? .verbose
        let level = BarsLog.parseLevel(env["BARS_LOG_LEVEL"]) ?? storedLevel
        BarsLog.bootstrapIfNeeded(.init(
            destination: .oslog(subsystem: "com.sirrayi.bars"),
            level: level,
            json: false))

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let gitCommit = Bundle.main.object(forInfoDictionaryKey: "CodexGitCommit") as? String ?? "unknown"
        let buildTimestamp = Bundle.main.object(forInfoDictionaryKey: "CodexBuildTimestamp") as? String ?? "unknown"
        BarsLog.logger(LogCategories.app).info(
            "bars starting",
            metadata: [
                "version": version,
                "build": build,
                "git": gitCommit,
                "built": buildTimestamp,
            ])

        KeychainAccessGate.isDisabled = SettingsStore.loadDebugDisableKeychainAccess(userDefaults: .standard)
        KeychainPromptCoordinator.install()
        if MainThreadHangWatchdog.isEnabledForCurrentProcess {
            MainThreadHangWatchdog.shared.start()
        }

        let preferencesSelection = PreferencesSelection()
        let settings = SettingsStore()
        Self.applyLanguagePreference(from: settings)
        configureUsageFormatterLocalizationProvider()
        let browserDetection = BrowserDetection(cacheTTL: BrowserDetection.defaultCacheTTL)
        let account = AccountInfo(email: nil, plan: nil)
        let store = UsageStore(browserDetection: browserDetection, settings: settings)
        self.preferencesSelection = preferencesSelection
        _settings = State(wrappedValue: settings)
        _store = State(wrappedValue: store)
        BarsLog.setLogLevel(settings.debugLogLevel)
        self.appDelegate.configure(.init(
            store: store,
            settings: settings,
            account: account,
            selection: preferencesSelection))
    }

    @SceneBuilder
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("About bars")) {
                    self.appDelegate.openSettings(pane: .about)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(self.settingsMenuTitle) {
                    self.appDelegate.openSettings(pane: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button(L("bars Help")) {
                    guard let url = URL(string: "https://github.com/steipete/CodexBar/blob/main/README.md")
                    else { return }
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var settingsMenuTitle: String {
        // Establish an Observation dependency so the command title follows in-app language changes.
        _ = self.settings.appLanguage
        return L("Settings...")
    }

    private static func applyLanguagePreference(from settings: SettingsStore) {
        AppLanguagePreferenceMigration.clearLegacyOverrideIfOwned(storedAppLanguage: settings.appLanguage)
        resetBarsLocalizationCache()
    }
}

// MARK: - Updater abstraction

@MainActor
protocol UpdaterProviding: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    var updateStatus: UpdateStatus { get }
    func checkForUpdates(_ sender: Any?)
    func installUpdate()
}

/// No-op updater used for debug builds and non-bundled runs to suppress Sparkle dialogs.
final class DisabledUpdaterController: UpdaterProviding {
    var automaticallyChecksForUpdates: Bool = false
    var automaticallyDownloadsUpdates: Bool = false
    let isAvailable: Bool = false
    let unavailableReason: String?
    let updateStatus = UpdateStatus()

    init(unavailableReason: String? = nil) {
        self.unavailableReason = unavailableReason
    }

    func checkForUpdates(_ sender: Any?) {}
    func installUpdate() {}
}

@MainActor
@Observable
final class UpdateStatus {
    var isUpdateReady = false
    /// A newer version that can be installed on demand, for updaters that do not stage downloads.
    var availableVersion: String?
    var isInstalling = false
}

/// This fork ships no auto-updater: upstream's Sparkle feed and Homebrew cask would replace it with official builds.
@MainActor
private func makeUpdaterController() -> UpdaterProviding {
    DisabledUpdaterController(unavailableReason: "Updates are managed manually in this build.")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let settingsMenuReadinessRetryCount = 2
    private static let settingsMenuFallbackVerificationRetryCount = 2

    struct Dependencies {
        let store: UsageStore
        let settings: SettingsStore
        let account: AccountInfo
        let selection: PreferencesSelection
    }

    let updaterController: UpdaterProviding = makeUpdaterController()
    let cloudSyncState = CloudSyncState()
    private let confettiOverlayController = ScreenConfettiOverlayController()
    private let confettiLogger = BarsLog.logger(LogCategories.confetti)
    private let dockIconController = DockIconController.shared
    private lazy var memoryPressureMonitor = MemoryPressureMonitor(trimAppCaches: { [weak self] in
        self?.trimRebuildableCachesForMemoryPressure() ?? MemoryPressureCacheTrimSummary()
    })

    private var statusController: StatusItemControlling?
    private var store: UsageStore?
    private var settings: SettingsStore?
    private var account: AccountInfo?
    private var preferencesSelection: PreferencesSelection?
    private var cloudSyncCoordinator: CloudSyncCoordinator?
    private var settingsWindowController: SettingsWindowController?
    private var pendingUpdateSettingsOpen = false
    private lazy var placeholderSettingsWindowGuard = PlaceholderSettingsWindowGuard(
        isKnownSettingsWindow: { [weak self] window in
            self?.settingsWindowController?.window === window
        })
    private var hasInstalledLimitResetObservers = false
    private var isWaitingForConfigPersistence = false
    #if DEBUG
    private var debugMemoryPressureObserver: NSObjectProtocol?
    #endif
    var terminateActiveProcessesForAppShutdown: () -> Void = {
        TTYCommandRunner.terminateActiveProcessesForAppShutdown()
    }

    var replyToApplicationShouldTerminate: (NSApplication, Bool) -> Void = { application, shouldTerminate in
        application.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    #if DEBUG
    func _test_configureSettings(_ settings: SettingsStore) {
        self.settings = settings
    }
    #endif

    func configure(_ dependencies: Dependencies) {
        self.store = dependencies.store
        self.settings = dependencies.settings
        self.account = dependencies.account
        self.preferencesSelection = dependencies.selection
        self.cloudSyncCoordinator = CloudSyncCoordinator(settings: dependencies.settings, state: self.cloudSyncState)
        self.settingsWindowController = SettingsWindowController(
            settings: dependencies.settings,
            store: dependencies.store,
            cloudSyncState: self.cloudSyncState,
            updater: self.updaterController,
            selection: dependencies.selection,
            runProviderLoginFlow: { [weak self] provider in
                guard let self else { return }
                await self.runProviderLoginFlow(provider)
            })
        if self.pendingUpdateSettingsOpen {
            self.pendingUpdateSettingsOpen = false
            self.openSettings(pane: .about)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        MenuBarStatusItemWindowProbe.trace("will-finish-launching")
        AppNotifications.shared.configureUpdateAction { [weak self] in
            guard let self else { return }
            if self.settingsWindowController == nil {
                self.pendingUpdateSettingsOpen = true
            } else {
                self.openSettings(pane: .about)
            }
        }
        self.configureAppIconForMacOSVersion()
        // The SwiftUI `Settings` scene is an empty placeholder; macOS otherwise presents it at launch.
        self.placeholderSettingsWindowGuard.start()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // bars lives in the menu bar and has no untitled document to open at launch or on reopen.
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarStatusItemWindowProbe.trace("did-finish-launching")
        WidgetExtensionRecovery.launch(reload: UsageStore.reloadWidgetTimelines)
        self.dockIconController.start()
        self.memoryPressureMonitor.start()
        #if DEBUG
        self.installDebugMemoryPressureObserverIfNeeded()
        #endif
        self.ensureStatusController()
        self.observeSettingsApplicationMenuLanguage()
        self.scheduleSettingsApplicationMenuValidation(
            missingItemRetriesRemaining: Self.settingsMenuReadinessRetryCount,
            fallbackVerificationRetriesRemaining: Self.settingsMenuFallbackVerificationRetryCount)
        self.cloudSyncCoordinator?.start()
        Task { await self.settings?.httpServer.startSaved() }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let settings = self?.settings else { return }
            AdaptiveActivityConsentPresenter.presentIfNeeded(settings: settings)
            AppNotifications.shared.requestAuthorizationOnStartup()
            // A persisted non-USD choice opts into the daily exchange-rate refresh. The service
            // returns before networking for the default USD setting and Auto.
            guard CurrencyExchange.requiresLiveRates(
                preferredCurrencyCode: settings.preferredCurrencyCode)
            else { return }
            await CurrencyExchange.shared.fetchLatestRatesIfNeeded(
                preferredCurrencyCode: settings.preferredCurrencyCode)
        }
        KeyboardShortcuts.onKeyUp(for: .openMenu) { [weak self] in
            // KeyboardShortcuts dispatches both normal and menu-tracking hotkeys on the main event loop.
            MainActor.assumeIsolated {
                self?.statusController?.openMenuFromShortcut()
            }
        }
        if !self.hasInstalledLimitResetObservers {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleSessionLimitResetNotification(_:)),
                name: .barsSessionLimitReset,
                object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleWeeklyLimitResetNotification(_:)),
                name: .barsWeeklyLimitReset,
                object: nil)
            self.hasInstalledLimitResetObservers = true
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !self.isWaitingForConfigPersistence else { return .terminateLater }
        let serverStop = self.settings?.httpServer.stopForTermination()
        let save = self.settings?.persistPendingConfigForTermination()
        guard save != nil || serverStop != nil else { return .terminateNow }
        self.isWaitingForConfigPersistence = true
        Task.detached {
            await save?.value
            await serverStop?.value
            // NSApplication may be inside a modal loop entered from the main dispatch queue.
            // A MainActor task cannot reliably resume there; deliver the reply on that run loop.
            RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                MainActor.assumeIsolated {
                    self.isWaitingForConfigPersistence = false
                    self.replyToApplicationShouldTerminate(sender, true)
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.cloudSyncCoordinator?.stop()
        self.memoryPressureMonitor.stop()
        #if DEBUG
        self.removeDebugMemoryPressureObserver()
        #endif
        self.statusController?.prepareForAppShutdown()
        self.confettiOverlayController.dismiss()
        self.dismissAppKitWindowsForShutdown()
        self.terminateActiveProcessesForAppShutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        self.cloudSyncCoordinator?.applicationDidBecomeActive()
    }

    func runProviderLoginFlow(_ provider: UsageProvider) async {
        self.ensureStatusController()
        guard let statusController else { return }
        await statusController.runLoginFlowFromSettings(provider: provider)
    }

    func openSettings(pane: SettingsPane?) {
        // Escape NSMenu's synchronous tracking callback before activating and presenting a window.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let settingsWindowController = self.settingsWindowController else {
                self.dockIconController.settingsWindowPresentationFailed()
                BarsLog.logger(LogCategories.app).error("Settings window controller was not configured")
                return
            }
            settingsWindowController.open(pane: pane)
        }
    }

    @objc private func showSettingsFromApplicationMenu(_: Any?) {
        self.openSettings(pane: nil)
    }

    @objc private func handleSessionLimitResetNotification(_ notification: Notification) {
        guard let event = notification.object as? SessionLimitResetEvent else { return }
        guard self.settings?.confettiOnSessionLimitResetsEnabled == true else { return }
        self.playLimitResetConfetti(
            provider: event.provider,
            accountIdentifier: event.accountIdentifier,
            resetKind: "session")
    }

    @objc private func handleWeeklyLimitResetNotification(_ notification: Notification) {
        guard let event = notification.object as? WeeklyLimitResetEvent else { return }
        guard self.settings?.confettiOnWeeklyLimitResetsEnabled == true else { return }
        self.playLimitResetConfetti(
            provider: event.provider,
            accountIdentifier: event.accountIdentifier,
            resetKind: "weekly")
    }

    private func playLimitResetConfetti(
        provider: UsageProvider,
        accountIdentifier: String,
        resetKind: String)
    {
        let origin = self.statusController?.celebrationOriginPoint(for: provider)
        let palette = ProviderDescriptorRegistry.descriptor(for: provider).branding.confettiPalette
        self.confettiLogger.info(
            "Triggering confetti",
            metadata: [
                "provider": provider.rawValue,
                "accountIdentifier": accountIdentifier,
                "resetKind": resetKind,
                "originKnown": origin == nil ? "0" : "1",
            ])
        self.confettiOverlayController.play(originInScreen: origin, colors: palette)
    }

    /// Use the classic (non-Liquid Glass) app icon on macOS versions before 26.
    private func configureAppIconForMacOSVersion() {
        if #unavailable(macOS 26) {
            self.applyClassicAppIcon()
        }
    }

    private func applyClassicAppIcon() {
        guard let classicIcon = Self.loadClassicIcon() else { return }
        NSApp.applicationIconImage = classicIcon
    }

    private static func loadClassicIcon() -> NSImage? {
        guard let url = self.classicIconURL(),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        return image
    }

    private static func classicIconURL() -> URL? {
        Bundle.main.url(forResource: "Icon-classic", withExtension: "icns")
    }

    private func dismissAppKitWindowsForShutdown() {
        guard let app = NSApp else { return }
        for window in app.windows {
            window.orderOut(nil)
        }
    }

    private func observeSettingsApplicationMenuLanguage() {
        guard let settings else { return }
        withObservationTracking {
            _ = settings.appLanguage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSettingsApplicationMenuLanguage()
                self.scheduleSettingsApplicationMenuValidation(
                    missingItemRetriesRemaining: Self.settingsMenuReadinessRetryCount,
                    fallbackVerificationRetriesRemaining: Self.settingsMenuFallbackVerificationRetryCount)
            }
        }
    }

    private func scheduleSettingsApplicationMenuValidation(
        missingItemRetriesRemaining: Int,
        fallbackVerificationRetriesRemaining: Int)
    {
        DispatchQueue.main.async { [weak self] in
            self?.ensureSingleSettingsApplicationMenuItem(
                missingItemRetriesRemaining: missingItemRetriesRemaining,
                fallbackVerificationRetriesRemaining: fallbackVerificationRetriesRemaining)
        }
    }

    private func ensureSingleSettingsApplicationMenuItem(
        missingItemRetriesRemaining: Int,
        fallbackVerificationRetriesRemaining: Int)
    {
        guard let mainMenu = NSApp.mainMenu else {
            if missingItemRetriesRemaining > 0 {
                self.scheduleSettingsApplicationMenuValidation(
                    missingItemRetriesRemaining: missingItemRetriesRemaining - 1,
                    fallbackVerificationRetriesRemaining: fallbackVerificationRetriesRemaining)
            } else {
                BarsLog.logger(LogCategories.app).error("Application menu unavailable for Settings validation")
            }
            return
        }
        let result = SettingsApplicationMenu.ensureSingleItem(
            in: mainMenu,
            localizedTitle: L("Settings..."),
            target: self,
            action: #selector(self.showSettingsFromApplicationMenu(_:)),
            allowMissingItemRepair: missingItemRetriesRemaining == 0)
        switch result {
        case let .unchanged(isFallback):
            if isFallback, fallbackVerificationRetriesRemaining > 0 {
                self.scheduleSettingsApplicationMenuValidation(
                    missingItemRetriesRemaining: Self.settingsMenuReadinessRetryCount,
                    fallbackVerificationRetriesRemaining: fallbackVerificationRetriesRemaining - 1)
            }
        case .retryNeeded:
            self.scheduleSettingsApplicationMenuValidation(
                missingItemRetriesRemaining: max(0, missingItemRetriesRemaining - 1),
                fallbackVerificationRetriesRemaining: fallbackVerificationRetriesRemaining)
        case let .repaired(previousCount, installedFallback):
            BarsLog.logger(LogCategories.app).warning(
                "Repaired application Settings menu",
                metadata: [
                    "installedFallback": installedFallback ? "1" : "0",
                    "previousCount": "\(previousCount)",
                ])
            if installedFallback, fallbackVerificationRetriesRemaining > 0 {
                self.scheduleSettingsApplicationMenuValidation(
                    missingItemRetriesRemaining: Self.settingsMenuReadinessRetryCount,
                    fallbackVerificationRetriesRemaining: fallbackVerificationRetriesRemaining - 1)
            }
        case .missingApplicationMenu:
            if missingItemRetriesRemaining > 0 {
                self.scheduleSettingsApplicationMenuValidation(
                    missingItemRetriesRemaining: missingItemRetriesRemaining - 1,
                    fallbackVerificationRetriesRemaining: fallbackVerificationRetriesRemaining)
            } else {
                BarsLog.logger(LogCategories.app).error("Could not repair application Settings menu")
            }
        }
    }

    private func ensureStatusController() {
        if self.statusController != nil {
            return
        }

        if let store,
           let settings,
           let account,
           let selection = self.preferencesSelection
        {
            let statusController = StatusItemController.factory(
                store,
                settings,
                account,
                self.updaterController,
                selection)
            statusController.setSettingsOpenHandler { [weak self] pane in
                self?.openSettings(pane: pane)
            }
            self.statusController = statusController
            if let concreteStatusController = statusController as? StatusItemController {
                concreteStatusController.cloudSyncState = self.cloudSyncState
                MenuSwitchFlickerProbe.startIfRequested(controller: concreteStatusController)
            }
            return
        }

        // Defensive fallback: this should not be hit in normal app lifecycle.
        BarsLog.logger(LogCategories.app)
            .error("StatusItemController fallback path used; settings/store mismatch likely.")
        assertionFailure("StatusItemController fallback path used; check app lifecycle wiring.")
        let fallbackSettings = SettingsStore()
        let browserDetection = BrowserDetection(cacheTTL: BrowserDetection.defaultCacheTTL)
        let fallbackAccount = AccountInfo(email: nil, plan: nil)
        let fallbackStore = UsageStore(browserDetection: browserDetection, settings: fallbackSettings)
        let statusController = StatusItemController.factory(
            fallbackStore,
            fallbackSettings,
            fallbackAccount,
            self.updaterController,
            PreferencesSelection())
        statusController.setSettingsOpenHandler { [weak self] pane in
            self?.openSettings(pane: pane)
        }
        self.statusController = statusController
    }

    private func trimRebuildableCachesForMemoryPressure() -> MemoryPressureCacheTrimSummary {
        var summary = MemoryPressureCacheTrimSummary()
        let statusSummary = self.statusController?.trimRebuildableCachesForMemoryPressure()
            ?? MemoryPressureCacheTrimSummary()
        summary.merge(statusSummary)
        return summary
    }

    #if DEBUG
    private func installDebugMemoryPressureObserverIfNeeded() {
        guard self.debugMemoryPressureObserver == nil else { return }
        self.debugMemoryPressureObserver = DistributedNotificationCenter.default().addObserver(
            forName: .barsDebugSimulateMemoryPressure,
            object: nil,
            queue: .main)
        { [weak self] notification in
            let rawLevel = notification.userInfo?["level"] as? String
            let shouldSeedCaches = notification.userInfo?["seedCaches"] as? String == "1"
            MainActor.assumeIsolated {
                self?.handleDebugMemoryPressureNotification(
                    rawLevel: rawLevel,
                    shouldSeedCaches: shouldSeedCaches)
            }
        }
    }

    private func removeDebugMemoryPressureObserver() {
        guard let observer = self.debugMemoryPressureObserver else { return }
        DistributedNotificationCenter.default().removeObserver(observer)
        self.debugMemoryPressureObserver = nil
    }

    private func handleDebugMemoryPressureNotification(rawLevel: String?, shouldSeedCaches: Bool) {
        let isCritical = rawLevel?.caseInsensitiveCompare("critical") == .orderedSame
        if shouldSeedCaches {
            self.statusController?.seedRebuildableCachesForMemoryPressureProof()
        }
        BarsLog.logger(LogCategories.memoryPressure).info(
            "Debug memory pressure notification received",
            metadata: [
                "level": isCritical ? "critical" : "warning",
                "seedCaches": shouldSeedCaches ? "1" : "0",
            ])
        self.memoryPressureMonitor.handleMemoryPressureForTesting(isWarning: !isCritical, isCritical: isCritical)
    }
    #endif

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
