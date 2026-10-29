import CoreGraphics
import Foundation

/// Bounds how often background refreshes may relaunch the Claude CLI for a usage probe (#2916).
/// Each CLI usage fetch spawns the full ~280 MB Claude Code binary for a few seconds, so background
/// work (timer ticks, menu opens, wake) reuses the last successful CLI result within a floor interval
/// instead of respawning. User-initiated refreshes always spawn so the manual Refresh action stays fresh.
/// Periodic timer ticks go further while nobody uses the Mac: Claude appends a local transcript on every turn, so
/// when none changed since the capture, usage on this Mac cannot have moved and the tick reuses the result up to
/// `maximumIdlePeriodicReuse`. Someone at the Mac may be using Claude on claude.ai, in the desktop app, or on a
/// phone while watching the menu bar, so any keyboard or pointer input since the capture relaunches instead.
enum ClaudeCLIUsageSpawnThrottle {
    struct Key: Hashable {
        let binary: String
        let accountScope: String
        let useWebExtras: Bool
        let includePrepaidBalance: Bool
    }

    struct Entry {
        let result: ProviderFetchResult
        let recordedAt: Date
    }

    /// Short enough that the configured refresh interval and each menu open get fresh usage, long enough
    /// that rapid menu opens or overlapping triggers share one probe.
    static let minimumBackgroundSpawnInterval: TimeInterval = 60

    /// Bounds how long periodic ticks trust an idle Mac, so usage from claude.ai or another device still appears.
    static let maximumIdlePeriodicReuse: TimeInterval = 30 * 60

    /// Transcript writes shortly before a capture may not be reflected in it yet, so they still count as new.
    static let activityLeadTime: TimeInterval = 2 * 60

    /// A larger transcript tree counts as activity rather than stretching the check; it then spawns as before.
    static let maximumActivityScanEntries = 20000

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Key: Entry] = [:]

        func insert(_ entry: Entry, for key: Key) {
            self.lock.withLock {
                self.entries[key] = entry
            }
        }

        func lookup(_ key: Key, now: Date) -> Entry? {
            self.lock.withLock {
                guard let entry = self.entries[key] else { return nil }
                guard now.timeIntervalSince(entry.recordedAt) < maximumIdlePeriodicReuse,
                      !ClaudeCLIUsageSpawnThrottle.anyWindowHasReset(in: entry.result.usage, now: now)
                else {
                    self.entries.removeValue(forKey: key)
                    return nil
                }
                return entry
            }
        }

        func removeAll() {
            self.lock.withLock {
                self.entries.removeAll()
            }
        }
    }

    private static let log = BarsLog.logger(LogCategories.provider(.claude, scope: "usage"))
    private static let sharedStore = Store()
    @TaskLocal private static var storeOverrideForTesting: Store?
    @TaskLocal private static var nowOverrideForTesting: (@Sendable () -> Date)?
    @TaskLocal private static var secondsSinceUserInputOverrideForTesting: TimeInterval?

    private static var store: Store {
        self.storeOverrideForTesting ?? self.sharedStore
    }

    private static var now: Date {
        self.nowOverrideForTesting?() ?? Date()
    }

    /// Seconds since the last keyboard, mouse, or trackpad event in this login session. Needs no permission.
    private static var secondsSinceUserInput: TimeInterval {
        if let override = self.secondsSinceUserInputOverrideForTesting { return override }
        // kCGAnyInputEventType; reads as fresh input if unavailable, which relaunches.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// nil when the Claude profile exposes no stable account identity
    /// (`ClaudeAccountProfile.identifiedSessionScope` returns nil) — such profiles are never cached.
    static func key(
        binary: String,
        environment: [String: String],
        useWebExtras: Bool,
        includePrepaidBalance: Bool) -> Key?
    {
        guard let accountScope = ClaudeAccountProfile.identifiedSessionScope(environment: environment) else {
            return nil
        }
        return Key(
            binary: binary,
            accountScope: accountScope,
            useWebExtras: useWebExtras,
            includePrepaidBalance: includePrepaidBalance)
    }

    /// Returns the cached result when it is younger than `minimumBackgroundSpawnInterval`, or, for a periodic tick,
    /// younger than `maximumIdlePeriodicReuse` with no input on the Mac since the capture and no local transcript
    /// written since shortly before it.
    /// A stale or missing entry returns nil (and an expired entry is removed).
    static func cachedResult(
        for key: Key,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderFetchResult?
    {
        let now = self.now
        guard let entry = self.store.lookup(key, now: now) else { return nil }
        let ageSeconds = max(0, now.timeIntervalSince(entry.recordedAt))
        if ageSeconds >= Self.minimumBackgroundSpawnInterval {
            guard ProviderRefreshTriggerContext.current == .periodic else { return nil }
            guard self.secondsSinceUserInput >= ageSeconds else {
                Self.log.debug("Mac in use since the cached CLI usage result; relaunching")
                return nil
            }
            guard !self.hasLocalTranscriptActivity(
                since: entry.recordedAt.addingTimeInterval(-Self.activityLeadTime),
                environment: environment)
            else {
                Self.log.debug("Local Claude activity since the cached CLI usage result; relaunching")
                return nil
            }
        }
        Self.log.debug(
            "Reusing cached Claude CLI usage result",
            metadata: ["ageSeconds": "\(ageSeconds)"])
        return entry.result
    }

    /// True when any local Claude transcript (the same roots the cost scan reads) changed after `cutoff`. bars's own
    /// probe project is skipped. Metadata only: no transcript is opened.
    static func hasLocalTranscriptActivity(
        since cutoff: Date,
        environment: [String: String],
        fileManager: FileManager = .default) -> Bool
    {
        let probeProjectName = ClaudeProbeSessionArtifactCleaner.claudeProjectDirectoryName(
            for: ClaudeStatusProbe.dedicatedProbeWorkingDirectoryURL())
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        var visited = 0
        for root in ClaudeConfigPaths.costProjectsRoots(environment: environment, fileManager: fileManager) {
            guard root.pathExtension != "jsonl" else {
                if let modified = try? root.resourceValues(forKeys: keys).contentModificationDate,
                   modified > cutoff { return true }
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator {
                visited += 1
                guard visited <= Self.maximumActivityScanEntries else { return true }
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isDirectory == true {
                    if url.lastPathComponent == probeProjectName { enumerator.skipDescendants() }
                    continue
                }
                if url.pathExtension == "jsonl", let modified = values.contentModificationDate, modified > cutoff {
                    return true
                }
            }
        }
        return false
    }

    static func record(_ result: ProviderFetchResult, for key: Key) {
        self.store.insert(Entry(result: result, recordedAt: self.now), for: key)
    }

    /// A cached result is unusable once any of its rate windows crosses its reset boundary: the
    /// session/weekly percentages then describe the previous window, and the reset-boundary refresh
    /// scheduler exists precisely to publish the post-reset state promptly.
    static func anyWindowHasReset(in usage: UsageSnapshot, now: Date) -> Bool {
        let windows = [usage.primary, usage.secondary, usage.tertiary]
            .compactMap(\.self)
            + (usage.extraRateWindows?.map(\.window) ?? [])
        return windows.contains { window in
            guard let resetsAt = window.resetsAt else { return false }
            return resetsAt <= now
        }
    }

    #if DEBUG
    static func withIsolatedStoreForTesting<T>(
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$storeOverrideForTesting.withValue(Store()) {
            try await operation()
        }
    }

    static func withNowOverrideForTesting<T>(
        _ now: @escaping @Sendable () -> Date,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$nowOverrideForTesting.withValue(now) {
            try await operation()
        }
    }

    static func withSecondsSinceUserInputOverrideForTesting<T>(
        _ seconds: TimeInterval,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$secondsSinceUserInputOverrideForTesting.withValue(seconds) {
            try await operation()
        }
    }
    #endif
}
