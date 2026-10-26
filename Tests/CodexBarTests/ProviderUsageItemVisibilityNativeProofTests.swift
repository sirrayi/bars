import AppKit
import CodexBarCore
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import CodexBar

/// Opt-in pointer-driven proof using production provider settings and contained synthetic stores.
@MainActor
final class ProviderUsageItemVisibilityNativeProofTests: XCTestCase {}

@MainActor
@Observable
private final class UsageVisibilityNativeState {
    let root: URL
    let provider: UsageProvider
    let configStore: CodexBarConfigStore
    var settings: SettingsStore
    var store: UsageStore
    var reloads = 0
    var fetchRevision: UInt64

    init(root: URL) throws {
        self.root = root
        self.provider = ProcessInfo.processInfo
            .environment["CODEXBAR_USAGE_VISIBILITY_NATIVE_PROOF_PROVIDER"] == "deepseek" ? .deepseek : .opencode
        self.configStore = CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json"))
        if try self.configStore.load() == nil {
            try self.configStore.save(CodexBarConfig(providers: UsageProvider.allCases.map {
                ProviderConfig(id: $0.instanceID, enabled: [.opencode, .claude, .deepseek].contains($0))
            }))
        }
        let settings = Self.makeSettings(root: root, configStore: self.configStore)
        self.settings = settings
        self.store = Self.makeStore(root: root, settings: settings)
        self.fetchRevision = settings.providerConfigRevision(for: self.provider)
    }

    func reload() {
        self.store.stopSharedSpendDashboardPublication()
        self.settings = Self.makeSettings(root: self.root, configStore: self.configStore)
        self.store = Self.makeStore(root: self.root, settings: self.settings)
        self.reloads += 1
    }

    func model(for provider: UsageProvider) -> UsageMenuCardView.Model {
        ProvidersPane(provider: provider, settings: self.settings, store: self.store)._test_menuCardModel(for: provider)
    }

    func receipt(window: NSWindow) -> [String: Any] {
        [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "window": window.windowNumber,
            "reloads": self.reloads,
            "provider": self.provider.rawValue,
            "hidden": self.settings.hiddenUsageItemIDs(for: self.provider).map(\.rawValue).sorted(),
            "detailSections": self.model(for: self.provider).providerDetails.map { $0.title ?? "(untitled)" },
            "detailRawTitles": self.model(for: self.provider).providerDetailRawTitles.map { $0 ?? "(untitled)" },
            "codexMetrics": self.model(for: .opencode).metrics.map(\.id),
            "claudeMetrics": self.model(for: .claude).metrics.map(\.id),
            "fetchRevisionUnchanged": self.settings.providerConfigRevision(for: self.provider) == self.fetchRevision,
        ]
    }

    private static func makeSettings(root: URL, configStore: CodexBarConfigStore) -> SettingsStore {
        let defaults = InMemoryUserDefaults(values: [
            AppGroupSupport.migrationVersionKey: AppGroupSupport.migrationVersion,
            "codexbar.legacySecretsMigrationCompleted": true,
            "providerDetectionCompleted": true,
            "debugDisableKeychainAccess": true,
        ])
        let settings = ProviderUsageItemVisibilityTests.settings(defaults: defaults, configStore: configStore)
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.refreshFrequency = .manual
        return settings
    }

    private static func environment(root: URL) -> [String: String] {
        [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent("codex-home").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("xdg-config").path,
        ]
    }

    private static func makeStore(root: URL, settings: SettingsStore) -> UsageStore {
        let environment = self.environment(root: root)
        let store = UsageStore(
            browserDetection: BrowserDetection(homeDirectory: root.path, cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store._test_providerRefreshOverride = { _ in XCTFail("Unexpected provider transport") }
        store._test_widgetSnapshotSaveOverride = { _ in }
        for provider in [UsageProvider.opencode, .claude, .deepseek] {
            let details = provider == .deepseek ? [
                try? ProviderDetailSection(
                    title: "Quota details",
                    rows: [.init(label: "Token quota", value: "25% used")]),
                try? ProviderDetailSection(rows: [.init(label: "Pool", value: "Synthetic untitled detail")]),
            ].compactMap(\.self) : []
            store._setSnapshotForTesting(UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 25,
                    windowMinutes: 300,
                    resetsAt: Date().addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 60,
                    windowMinutes: 10080,
                    resetsAt: Date().addingTimeInterval(172_800),
                    resetDescription: nil),
                details: details,
                updatedAt: Date()), provider: provider)
        }
        return store
    }
}

@MainActor
private struct UsageVisibilityNativeView: View {
    @Bindable var state: UsageVisibilityNativeState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Synthetic data · production provider settings")
                Spacer()
                Button("Reload persisted settings") { self.state.reload() }
                    .accessibilityIdentifier("proof-reload-settings")
            }
            .padding(12)
            ProvidersPane(provider: self.state.provider, settings: self.state.settings, store: self.state.store)
                .id(self.state.reloads)
        }
    }
}
