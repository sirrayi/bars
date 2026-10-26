import Testing
@testable import CodexBarCore

enum ProviderDescriptorRegistryStorageTests {
    private static func descriptor(_ id: UsageProvider, name: String) -> ProviderDescriptor {
        let base = ProviderDescriptorRegistry.descriptor(for: id)
        return ProviderDescriptor(
            id: id,
            metadata: base.metadata,
            branding: base.branding,
            tokenCost: base.tokenCost,
            fetchPlan: base.fetchPlan,
            cli: ProviderCLIConfig(name: name, versionDetector: nil))
    }
}
