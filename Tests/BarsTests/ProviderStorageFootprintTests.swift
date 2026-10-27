import AppKit
import BarsCore
import Foundation
import Observation
import Testing
@testable import Bars

struct ProviderStorageFootprintTests {
    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            self.lock.lock()
            self.value = true
            self.lock.unlock()
        }

        func get() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

    @Test
    func `global low power mode clamps automatic storage scans to thirty minutes`() {
        #expect(UsageStore.automaticStorageRefreshInterval(lowPowerModeEnabled: false) == 5 * 60)
        #expect(UsageStore.automaticStorageRefreshInterval(lowPowerModeEnabled: true) == 30 * 60)
    }

    @Test
    func `scanner sums nested regular files and skips symlink targets`() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: root.appendingPathComponent("a.jsonl"))
        try Data(repeating: 2, count: 7).write(to: nested.appendingPathComponent("b.jsonl"))

        let external = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: external) }
        let target = external.appendingPathComponent("outside.bin")
        try Data(repeating: 3, count: 100).write(to: target)
        let link = root.appendingPathComponent("linked.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let footprint = ProviderStorageScanner().scan(provider: .opencode, candidatePaths: [root.path])

        #expect(footprint.totalBytes == 12)
        #expect(footprint.paths == [root.path])
        #expect(footprint.missingPaths.isEmpty)
        #expect(footprint.components.map(\.name) == ["nested", "a.jsonl"])
        #expect(footprint.components.map(\.totalBytes) == [7, 5])
    }

    @Test
    func `scanner does not follow symlinked candidate roots`() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: target.appendingPathComponent("session.jsonl"))
        let symlinkRoot = root.appendingPathComponent("codex-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: target)

        let footprint = ProviderStorageScanner().scan(provider: .opencode, candidatePaths: [symlinkRoot.path])

        #expect(footprint.paths == [symlinkRoot.path])
        #expect(footprint.totalBytes == 0)
        #expect(footprint.components.isEmpty)
    }

    @Test(arguments: [false, true])
    func `scanner groups files without changing literal component names`(usesUnnormalizedRoot: Bool) throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unused = root.appendingPathComponent("unused", isDirectory: true)
        try FileManager.default.createDirectory(at: unused, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent("group %2F 空格", isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: directory.appendingPathComponent("first.jsonl"))
        try Data(repeating: 2, count: 7).write(to: nested.appendingPathComponent("second.jsonl"))
        try Data(repeating: 3, count: 3).write(to: root.appendingPathComponent("top level.bin"))
        let candidatePath = usesUnnormalizedRoot ? unused.path + "/../" : root.path

        let footprint = ProviderStorageScanner().scan(provider: .opencode, candidatePaths: [candidatePath])

        #expect(footprint.totalBytes == 15)
        #expect(footprint.paths == [candidatePath])
        #expect(footprint.unreadablePaths.isEmpty)
        #expect(footprint.components.map(\.name) == ["group %2F 空格", "top level.bin"])
        #expect(footprint.components.map(\.totalBytes) == [12, 3])
        #expect(footprint.components.map(\.path) == [
            directory.standardizedFileURL.path,
            root.appendingPathComponent("top level.bin").standardizedFileURL.path,
        ])
    }

    @Test
    func `scanner records missing paths without failing`() throws {
        let root = try Self.makeTemporaryDirectory()
        let missing = root.appendingPathComponent("missing")
        defer { try? FileManager.default.removeItem(at: root) }

        let footprint = ProviderStorageScanner().scan(provider: .claude, candidatePaths: [missing.path])

        #expect(footprint.totalBytes == 0)
        #expect(footprint.paths.isEmpty)
        #expect(footprint.missingPaths == [missing.path])
    }

    @Test
    func `claude path catalog uses the environment home by default`() {
        let paths = ProviderStoragePathCatalog.candidatePaths(
            for: .claude,
            environment: ["HOME": "/tmp/claude-home"])

        #expect(paths == [
            "/tmp/claude-home/.claude",
            "/tmp/claude-home/.config/claude",
            "/tmp/claude-home/Library/Application Support/bars/ClaudeProbe",
        ])
    }

    @Test
    func `claude path catalog replaces default roots with CLAUDE_CONFIG_DIR`() {
        let paths = ProviderStoragePathCatalog.candidatePaths(
            for: .claude,
            environment: ["HOME": "/tmp/claude-home", "CLAUDE_CONFIG_DIR": "/tmp/claude-profile"])

        #expect(paths == [
            "/tmp/claude-profile",
            "/tmp/claude-home/Library/Application Support/bars/ClaudeProbe",
        ])
    }

    @Test
    func `claude recommendations use documented cleanup categories`() {
        let root = "/Users/test/.claude"
        let footprint = ProviderStorageFootprint(
            provider: .claude,
            totalBytes: 28,
            paths: [root],
            missingPaths: [],
            unreadablePaths: [],
            components: [
                .init(path: "\(root)/projects", totalBytes: 10),
                .init(path: "\(root)/file-history", totalBytes: 8),
                .init(path: "\(root)/paste-cache", totalBytes: 6),
                .init(path: "\(root)/settings.json", totalBytes: 4),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))

        let recommendations = footprint.cleanupRecommendations

        #expect(recommendations.map(\.path) == [
            "\(root)/projects",
            "\(root)/file-history",
            "\(root)/paste-cache",
        ])
        #expect(recommendations[0].consequence.contains("resume"))
        #expect(recommendations.allSatisfy { $0.riskLevel == .manualCleanup })
    }

    @Test
    @MainActor
    func `overview row carries storage text outside provider detail model`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: nil)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let overview = OverviewMenuCardRowView(model: model, storageText: "1.5 GB", width: 310)
        let detail = UsageMenuCardView(model: model, width: 310)

        #expect(overview.storageText == "1.5 GB")
        #expect(detail.model.provider == UsageProvider.claude)
    }

    @Test
    @MainActor
    func `storage detail view exposes cleanup recommendations while overview remains number only`() throws {
        let root = "/Users/test/.claude"
        let footprint = ProviderStorageFootprint(
            provider: .claude,
            totalBytes: 10,
            paths: [root],
            missingPaths: [],
            unreadablePaths: [],
            components: [
                .init(path: "\(root)/projects", totalBytes: 10),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))
        let detailView = StorageBreakdownMenuView(footprint: footprint, width: 310)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Date(timeIntervalSince1970: 0)))
        let overview = OverviewMenuCardRowView(model: model, storageText: "10 B", width: 310)

        #expect(detailView.cleanupRecommendations.map(\.path) == ["\(root)/projects"])
        #expect(overview.storageText == "10 B")
    }

    @Test
    @MainActor
    func `storage detail view exposes copyable exact paths`() {
        let root = "/Users/test/.claude"
        let footprint = ProviderStorageFootprint(
            provider: .claude,
            totalBytes: 110,
            paths: [root],
            missingPaths: [],
            unreadablePaths: [],
            components: [
                .init(path: "\(root)/projects", totalBytes: 100),
                .init(path: "\(root)/file-history", totalBytes: 10),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))
        let detailView = StorageBreakdownMenuView(footprint: footprint, width: 310)

        #expect(detailView.copyablePaths.contains("\(root)/projects"))
        #expect(detailView.copyablePaths.contains("\(root)/file-history"))
    }

    @Test
    @MainActor
    func `manual storage refresh updates deleted provider data`() async throws {
        let home = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let configRoot = home.appendingPathComponent("claude-config", isDirectory: true)
        let sessions = configRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: sessions.appendingPathComponent("session.jsonl"))

        let suite = "ProviderStorageFootprintTests-storage-refresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        if let metadata = ProviderDefaults.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        }
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: ["HOME": home.path, "CLAUDE_CONFIG_DIR": configRoot.path])
        settings.providerStorageFootprintsEnabled = true
        settings.backgroundWorkLowPowerModePreference = .on

        await store.refreshStorageFootprintsForOverviewNow()
        #expect(store.storageFootprint(for: .claude)?.totalBytes == 32)

        try FileManager.default.removeItem(at: sessions)
        await store.refreshStorageFootprintsForOverviewNow()

        #expect(store.storageFootprint(for: .claude)?.totalBytes == 0)
        #expect(store.storageFootprintText(for: .claude) == "No local data found")
    }

    @Test
    @MainActor
    func `repeated identical storage refresh does not republish observable footprints`() async throws {
        let home = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let configRoot = home.appendingPathComponent("claude-config", isDirectory: true)
        let sessions = configRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: sessions.appendingPathComponent("session.jsonl"))

        let suite = "ProviderStorageFootprintTests-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        if let metadata = ProviderDefaults.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        }
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: ["HOME": home.path, "CLAUDE_CONFIG_DIR": configRoot.path])
        settings.providerStorageFootprintsEnabled = true

        await store.refreshStorageFootprintsNow(for: [.claude])
        #expect(store.storageFootprint(for: .claude)?.totalBytes == 32)

        // A second scan over identical on-disk data must not re-assign the observable property.
        // Storage scans run on every menu open and every ~5 min; an unconditional re-publish wakes
        // the controller's `menuObservationToken` -> `invalidateMenus` path for no value change.
        let didRepublish = ObservationFlag()
        withObservationTracking {
            _ = store.providerStorageFootprints
        } onChange: {
            didRepublish.set()
        }
        await store.refreshStorageFootprintsNow(for: [.claude])
        try? await Task.sleep(for: .milliseconds(50))

        #expect(didRepublish.get() == false)
        #expect(store.storageFootprint(for: .claude)?.totalBytes == 32)
    }

    @Test
    @MainActor
    func `storage refresh is opt in and clears stale footprints when disabled`() async throws {
        let home = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let configRoot = home.appendingPathComponent("claude-config", isDirectory: true)
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16).write(to: configRoot.appendingPathComponent("session.jsonl"))

        let suite = "ProviderStorageFootprintTests-storage-opt-in-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        if let metadata = ProviderDefaults.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        }
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: ["HOME": home.path, "CLAUDE_CONFIG_DIR": configRoot.path])

        await store.refreshStorageFootprintsForOverviewNow()
        #expect(store.storageFootprint(for: .claude) == nil)

        settings.providerStorageFootprintsEnabled = true
        await store.refreshStorageFootprintsForOverviewNow()
        #expect(store.storageFootprint(for: .claude)?.totalBytes == 16)

        settings.providerStorageFootprintsEnabled = false
        await store.refreshStorageFootprintsForOverviewNow()
        #expect(store.storageFootprint(for: .claude) == nil)
        #expect(store.providerStorageFootprints.isEmpty)
    }

    @Test
    @MainActor
    func `forced scheduled storage refresh does not restart identical in flight scan`() throws {
        let home = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let configRoot = home.appendingPathComponent("claude-config", isDirectory: true)
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)

        let suite = "ProviderStorageFootprintTests-storage-in-flight-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite))
        let store = UsageStore(
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: ["HOME": home.path, "CLAUDE_CONFIG_DIR": configRoot.path])
        settings.providerStorageFootprintsEnabled = true
        store.storageRefreshGeneration = 41
        let paths = ProviderStoragePathCatalog.candidatePaths(
            for: .claude,
            environment: ["HOME": home.path, "CLAUDE_CONFIG_DIR": configRoot.path])
        store.storageRefreshInFlightSignature = "claude=\(paths.joined(separator: "\u{1f}"))"
        store.storageRefreshTask = Task.detached {
            try? await Task.sleep(for: .seconds(30))
        }
        defer {
            store.storageRefreshTask?.cancel()
            store.storageRefreshTask = nil
            store.storageRefreshInFlightSignature = nil
        }

        store.scheduleStorageFootprintRefresh(for: [.claude], force: true)

        #expect(store.storageRefreshGeneration == 41)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderStorageFootprintTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
