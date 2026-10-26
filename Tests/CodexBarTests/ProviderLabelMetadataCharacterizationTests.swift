import CodexBarCore
import Testing

struct ProviderLabelMetadataCharacterizationTests {
    // MARK: - Label non-empty constraints

    @Test
    func `displayName is non-empty for all providers`() {
        for descriptor in ProviderDescriptorRegistry.all {
            #expect(
                !descriptor.metadata.displayName.isEmpty,
                "Provider \(descriptor.id.rawValue) has empty displayName.")
        }
    }

    @Test
    func `sessionLabel is non-empty for all providers`() {
        for descriptor in ProviderDescriptorRegistry.all {
            #expect(
                !descriptor.metadata.sessionLabel.isEmpty,
                "Provider \(descriptor.id.rawValue) has empty sessionLabel.")
        }
    }

    // MARK: - Known empty weeklyLabel exceptions

    // MARK: - Invariant: supportsOpus implies opusLabel

    @Test
    func `supportsOpus providers declare non-empty opusLabel`() {
        for descriptor in ProviderDescriptorRegistry.all where descriptor.metadata.supportsOpus {
            #expect(
                descriptor.metadata.opusLabel != nil && !descriptor.metadata.opusLabel!.isEmpty,
                "Provider \(descriptor.id.rawValue) has supportsOpus=true but opusLabel is nil or empty.")
        }
    }

    // MARK: - opusLabel structural constraint

    @Test
    func `opusLabel is nil or non-empty`() {
        for descriptor in ProviderDescriptorRegistry.all {
            if let opusLabel = descriptor.metadata.opusLabel {
                #expect(
                    !opusLabel.isEmpty,
                    "Provider \(descriptor.id.rawValue) has empty opusLabel string instead of nil.")
            }
        }
    }
}
