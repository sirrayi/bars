import Foundation

/// Live-only ownership marker for a browser-session-derived fetch. Neither cookie values nor the
/// digest are serialized.
public struct ProviderBrowserSessionOwner: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let profile: ProviderBrowserProfile
    public let digest: String

    public init(profile: ProviderBrowserProfile, digest: String) {
        self.profile = profile
        self.digest = digest
    }

    public var description: String {
        "<live browser session>"
    }

    public var debugDescription: String {
        self.description
    }
}

public struct ProviderBrowserSessionFailure: LocalizedError, Sendable, CustomDebugStringConvertible {
    public let owner: ProviderBrowserSessionOwner?
    public let underlyingError: Error

    public init(owner: ProviderBrowserSessionOwner?, underlyingError: Error) {
        self.owner = owner
        self.underlyingError = underlyingError
    }

    public var errorDescription: String? {
        self.underlyingError.localizedDescription
    }

    public var debugDescription: String {
        self.underlyingError.localizedDescription
    }
}
