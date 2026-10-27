import AppKit
import BarsCore
import Foundation
import Testing
@testable import Bars

@MainActor
struct ProviderIconResourcesTests {
    @Test
    func `provider brand icons are cached after first load`() throws {
        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }

        let first = try #require(ProviderBrandIcon.image(for: .claude))
        let second = try #require(ProviderBrandIcon.image(for: .claude))

        #expect(first === second)
        #expect(first.size == NSSize(width: 18, height: 18))
        #expect(first.isTemplate)
    }

    @Test
    func `devin uses the official hexagonal mark across app and serve`() throws {
        let root = try Self.repoRoot()
        let svg = try String(
            contentsOf: root.appending(path: "Sources/Bars/Resources/ProviderIcon-devin.svg"),
            encoding: .utf8)
        #expect(svg.contains("fill=\"currentColor\""))
        #expect(svg.contains("viewBox=\"0 0 128 128\""))
        #expect(svg.contains("M23 48.6315V29.1756C23 28.3205"))
        #expect(!svg.contains("<rect"))
        #expect(!svg.contains("M12 2.25c1.18 0 2.18.76"))
        let cli = try String(
            contentsOf: root.appending(path: "Sources/BarsCLI/CLIServeProviderIcons.swift"), encoding: .utf8)
        #expect(cli.contains("\"ProviderIcon-devin\": \"\(Data(svg.utf8).base64EncodedString())\""))

        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }
        let image = try #require(ProviderBrandIcon.image(for: .devin))
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.isTemplate)
    }

    @Test
    func `registered providers resolve bundled brand icons`() {
        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }

        for provider in UsageProvider.allCases {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            #expect(
                ProviderBrandIcon.image(for: provider) != nil,
                "Missing icon resource \(descriptor.branding.iconResourceName).svg for \(provider.rawValue)")
        }
    }

    private static func repoRoot() throws -> URL {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appending(path: "Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "ProviderIconResourcesTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate repo root (Package.swift) from \(#filePath)",
        ])
    }
}
