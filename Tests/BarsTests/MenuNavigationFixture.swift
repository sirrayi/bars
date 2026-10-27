import AppKit
import BarsCore
import Foundation
import Testing
@testable import Bars

@MainActor
struct MenuNavigationFixture {
    let files: CostUsageTestEnvironment
    let settings: SettingsStore
    let store: UsageStore

    init(userDefaults: UserDefaults? = nil) throws {
        self.files = try CostUsageTestEnvironment()
        self.settings = testSettingsStore(
            suiteName: "MenuNavigationFixture",
            userDefaults: userDefaults,
            config: BarsConfig(providers: UsageProvider.allCases.map {
                ProviderConfig(id: $0.instanceID, enabled: $0 == .claude)
            }),
            prepareDefaults: {
                // Isolation must precede SettingsStore's synchronous legacy migration.
                $0.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
                $0.set(true, forKey: "bars.legacySecretsMigrationCompleted")
                $0.set(true, forKey: "debugDisableKeychainAccess")
                $0.set(true, forKey: "providerDetectionCompleted")
            })
        self.settings.statusChecksEnabled = false
        self.settings.costUsageEnabled = false
        self.settings.refreshFrequency = .manual
        let environment = [
            "HOME": self.files.root.path,
            "XDG_CONFIG_HOME": self.files.root.appendingPathComponent(".config").path,
        ]
        self.store = UsageStore(
            browserDetection: BrowserDetection(homeDirectory: self.files.root.path, cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(cacheRoot: self.files.cacheRoot),
            settings: self.settings,
            startupBehavior: .testing,
            environmentBase: environment)
        self.store._test_providerRefreshOverride = { _ in Issue.record("Unexpected provider transport") }
        self.store._test_widgetSnapshotSaveOverride = { _ in }
    }

    func makeController() -> StatusItemController {
        StatusItemController(
            store: self.store,
            settings: self.settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    func cleanup() {
        self.store.stopSharedSpendDashboardPublication()
        self.files.cleanup()
    }
}
