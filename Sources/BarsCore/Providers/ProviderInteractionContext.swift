import Foundation

public enum ProviderInteraction: Sendable, Equatable {
    case background
    case userInitiated
}

public enum ProviderInteractionContext {
    @TaskLocal public static var current: ProviderInteraction = .background
}

public enum ProviderRefreshPhase: Sendable, Equatable {
    case regular
    case startup
}

public enum ProviderRefreshContext {
    @TaskLocal public static var current: ProviderRefreshPhase = .regular
}

/// Only the automatic refresh timer marks its ticks `.periodic`; launch, wake, menu-open, settings, and manual
/// refreshes stay `.onDemand`. Providers with an expensive probe may skip periodic work that cannot change the result.
public enum ProviderRefreshTrigger: Sendable, Equatable {
    case onDemand
    case periodic
}

public enum ProviderRefreshTriggerContext {
    @TaskLocal public static var current: ProviderRefreshTrigger = .onDemand
}

public enum ProviderRefreshRequestContext {
    @TaskLocal public static var id: UUID?

    public static func withNewRequest<T>(
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        // Keep the nontrivial UUID value in the async frame. Passing UUID() directly to
        // TaskLocal.withValue mis-nests task allocations in the macOS 14 backdeployment thunk.
        let requestID: UUID? = UUID()
        return try await self.$id.withValue(requestID, operation: operation)
    }
}
