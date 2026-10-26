import CodexBarCore
import Foundation
@testable import CodexBar

/// Fetch strategy that returns a canned snapshot so store refresh tests never touch a real provider transport.
struct StubProviderFetchStrategy: ProviderFetchStrategy {
    let loader: @Sendable () async throws -> UsageSnapshot

    var id: String {
        "stub-provider-fetch"
    }

    var kind: ProviderFetchKind {
        .cli
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        try await self.makeResult(usage: self.loader(), sourceLabel: self.id)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

extension ProviderSpec {
    /// Copies a registered spec, replacing only its fetch pipeline with a stubbed loader.
    static func stubbed(
        _ baseSpec: ProviderSpec,
        loader: @escaping @Sendable () async throws -> UsageSnapshot) -> ProviderSpec
    {
        let base = baseSpec.descriptor
        let strategy = StubProviderFetchStrategy(loader: loader)
        return ProviderSpec(
            style: baseSpec.style,
            isEnabled: baseSpec.isEnabled,
            descriptor: ProviderDescriptor(
                id: base.id,
                metadata: base.metadata,
                branding: base.branding,
                tokenCost: base.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.auto, .cli, .oauth, .web, .api],
                    pipeline: ProviderFetchPipeline { _ in [strategy] }),
                cli: base.cli),
            makeFetchContext: baseSpec.makeFetchContext)
    }
}
