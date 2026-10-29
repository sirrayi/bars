import Foundation

enum ClaudeCLIRateLimitGate {
    private static let blockedUntilKey = "claudeCLIUsageRateLimitBlockedUntilV1"
    private static let defaultCooldown: TimeInterval = 60 * 5
    /// Scheduled refreshes keep a fixed beat but can each fire up to 30 s late, and the cooldown starts when the
    /// probe that tripped it finishes, so it can still have seconds left at the next tick and hold the retry for a
    /// whole extra interval. Background checks treat a cooldown with no more than this left as over.
    private static let backgroundSlack: TimeInterval = 60

    static let message = "Claude CLI usage endpoint is rate limited right now. Please try again later."
    /// Claude answers `/usage` with the rows it saved at its last successful fetch whenever the endpoint refuses,
    /// and reports some refusals (HTTP 403 holds) only as "could not refresh", so that answer waits out the same
    /// cooldown.
    static let lastKnownUsageMessage =
        "Claude CLI could not refresh usage data and only showed its last-known values. Please try again later."
    /// With no saved rows to show, Claude answers any other endpoint failure with only "Failed to load usage data";
    /// once the direct `/usage` fallback fails as well, that answer waits out the same cooldown.
    static let loadFailedMessage = "Claude CLI could not load usage data right now. Please try again later."

    /// Claude refusing to refresh usage is not output bars failed to parse, so error descriptions show these as is.
    static func isEndpointRefusalMessage(_ message: String) -> Bool {
        [self.message, self.lastKnownUsageMessage, self.loadFailedMessage].contains(message)
    }

    static func blockedUntil(
        interaction: ProviderInteraction = ProviderInteractionContext.current,
        now: Date = Date()) -> Date?
    {
        guard interaction != .userInitiated,
              let blockedUntil = self.currentBlockedUntil(now: now),
              blockedUntil.timeIntervalSince(now) > self.backgroundSlack
        else { return nil }
        return blockedUntil
    }

    static func currentBlockedUntil(now: Date = Date()) -> Date? {
        guard let raw = self.storedBlockedUntil() else {
            return nil
        }

        let blockedUntil = Date(timeIntervalSince1970: raw)
        guard blockedUntil > now else {
            self.storeBlockedUntil(nil)
            return nil
        }
        return blockedUntil
    }

    static func recordRateLimit(now: Date = Date()) {
        self.storeBlockedUntil(now.addingTimeInterval(self.defaultCooldown).timeIntervalSince1970)
    }

    static func recordSuccess() {
        self.storeBlockedUntil(nil)
    }

    /// Holds the cooldown for tests in place of standard defaults, where it outlasts a relaunch.
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var blockedUntil: Double?

        var value: Double? {
            get { self.lock.withLock { self.blockedUntil } }
            set { self.lock.withLock { self.blockedUntil = newValue } }
        }
    }

    @TaskLocal private static var storeOverrideForTesting: Store?

    private static func storedBlockedUntil() -> Double? {
        if let store = self.storeOverrideForTesting { return store.value }
        return UserDefaults.standard.object(forKey: self.blockedUntilKey) as? Double
    }

    private static func storeBlockedUntil(_ value: Double?) {
        if let store = self.storeOverrideForTesting {
            store.value = value
        } else if let value {
            UserDefaults.standard.set(value, forKey: self.blockedUntilKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
        }
    }

    static func isRateLimitError(_ error: Error) -> Bool {
        if case let ClaudeStatusProbeError.parseFailed(message) = error {
            return self.isRateLimitMessage(message, allowRawRateLimitToken: true)
        }
        if case let ClaudeUsageError.parseFailed(message) = error {
            return self.isRateLimitMessage(message, allowRawRateLimitToken: true)
        }
        return self.isRateLimitMessage(error.localizedDescription, allowRawRateLimitToken: false)
    }

    private static func isRateLimitMessage(_ message: String, allowRawRateLimitToken: Bool) -> Bool {
        let lower = message.lowercased()
        return lower.contains(Self.message.lowercased()) ||
            lower.contains(Self.lastKnownUsageMessage.lowercased()) ||
            lower.contains(Self.loadFailedMessage.lowercased()) ||
            (allowRawRateLimitToken && lower.contains("rate_limit_error")) ||
            (lower.contains("claude cli") &&
                lower.contains("usage") &&
                lower.contains("rate limited"))
    }

    #if DEBUG
    static func resetForTesting() {
        self.storeBlockedUntil(nil)
    }

    /// Gives `operation` its own cooldown, so a probe that trips it cannot hold back probes in parallel tests.
    static func withIsolatedCooldownForTesting<T>(operation: () async throws -> T) async rethrows -> T {
        try await self.$storeOverrideForTesting.withValue(Store()) {
            try await operation()
        }
    }
    #endif
}
