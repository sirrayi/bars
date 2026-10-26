import CodexBarCore
import Testing
@testable import CodexBar

struct ProviderRegistryTests {
    @Test
    func `descriptor registry is complete and deterministic`() {
        let descriptors = ProviderDescriptorRegistry.all
        let ids = descriptors.map(\.id)

        #expect(!descriptors.isEmpty, "ProviderDescriptorRegistry must not be empty.")
        #expect(Set(ids).count == ids.count, "ProviderDescriptorRegistry contains duplicate IDs.")

        let missing = Set(UsageProvider.allCases).subtracting(ids)
        #expect(missing.isEmpty, "Missing descriptors for providers: \(missing).")
        #expect(ids == UsageProvider.allCases, "Descriptor manifest order must match UsageProvider.")

        let secondPass = ProviderDescriptorRegistry.all.map(\.id)
        #expect(ids == secondPass, "ProviderDescriptorRegistry order changed between reads.")
    }

    @Test
    func `implementation catalog is complete and deterministic`() {
        let implementations = ProviderCatalog.all
        let ids = implementations.map(\.id)

        #expect(!implementations.isEmpty, "ProviderCatalog must not be empty.")
        #expect(Set(ids).count == ids.count, "ProviderCatalog contains duplicate IDs.")

        let missing = Set(UsageProvider.allCases).subtracting(ids)
        #expect(missing.isEmpty, "Missing implementations for providers: \(missing).")
        #expect(ids == UsageProvider.allCases, "Implementation manifest order must match UsageProvider.")

        let secondPass = ProviderCatalog.all.map(\.id)
        #expect(ids == secondPass, "ProviderCatalog order changed between reads.")
    }
}
