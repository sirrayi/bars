import AppKit
import SwiftUI
import XCTest
@testable import Bars
@testable import BarsCore

/// Opt-in native proof through the actual status-item and editor data builders.
@MainActor
final class MenuBarBalanceNativeProofTests: XCTestCase {
    private static func settings(root: URL, providers: [UsageProvider]) throws -> SettingsStore {
        let defaults = InMemoryUserDefaults(values: [
            "debugDisableKeychainAccess": true, "bars.legacySecretsMigrationCompleted": true,
            "providerDetectionCompleted": true, "openAIWebAccessEnabled": false, "launchAtLogin": false,
            "tokenCostUsageEnabled": false, "agentSessionsEnabled": false,
        ])
        let config = BarsConfigStore(fileURL: root.appendingPathComponent("config.json"))
        try config.save(BarsConfig(providers: UsageProvider.allCases.map {
            ProviderConfig(id: $0.instanceID, enabled: providers.contains($0))
        }))
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: config,
            claudeCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            tokenAccountStore: InMemoryTokenAccountStore(fileURL: root.appendingPathComponent("accounts.json")),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }),
            performInitialProviderDetection: false)
        settings.refreshFrequency = .manual
        settings.refreshAllProvidersOnMenuOpen = false
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.mergeIcons = false
        settings.hidePersonalInfo = true
        settings.menuBarIconStyle = .iconAndPercent
        settings.menuBarLayoutConditionals = []
        return settings
    }
}
