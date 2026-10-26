import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProviderIconResourcesTests {
    @Test
    func `groq and grok provider icons are distinct`() throws {
        let root = try Self.repoRoot()
        let resources = root.appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)
        let groq = try String(contentsOf: resources.appending(path: "ProviderIcon-groq.svg"), encoding: .utf8)
        let grok = try String(contentsOf: resources.appending(path: "ProviderIcon-grok.svg"), encoding: .utf8)

        #expect(groq != grok)
    }

    @Test
    func `grok and xai provider icons are distinct`() throws {
        let root = try Self.repoRoot()
        let resources = root.appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)
        let grok = try String(contentsOf: resources.appending(path: "ProviderIcon-grok.svg"), encoding: .utf8)
        let xai = try String(contentsOf: resources.appending(path: "ProviderIcon-xai.svg"), encoding: .utf8)

        #expect(grok != xai)
    }

    @Test
    func `provider brand icons are cached after first load`() throws {
        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }

        let first = try #require(ProviderBrandIcon.image(for: .codex))
        let second = try #require(ProviderBrandIcon.image(for: .codex))

        #expect(first === second)
        #expect(first.size == NSSize(width: 18, height: 18))
        #expect(first.isTemplate)
    }

    @Test
    func `replicate uses the official glyph across app website and serve`() throws {
        let root = try Self.repoRoot()
        let svg = try String(
            contentsOf: root.appending(path: "Sources/CodexBar/Resources/ProviderIcon-replicate.svg"),
            encoding: .utf8)
        #expect(svg.contains("fill=\"currentColor\""))
        #expect(svg.contains("viewBox=\"-125 -125 1250 1250\""))
        for points in [
            "1000,427.6 1000,540.6 603.4,540.6 603.4,1000 477,1000 477,427.6",
            "1000,213.8 1000,327 364.8,327 364.8,1000 238.4,1000 238.4,213.8",
            "1000,0 1000,113.2 126.4,113.2 126.4,1000 0,1000 0,0",
        ] {
            #expect(svg.contains("points=\"\(points)\""))
        }
        let website = try String(contentsOf: root.appending(path: "docs/logos/replicate.svg"), encoding: .utf8)
        #expect(website == svg)
        let cli = try String(
            contentsOf: root.appending(path: "Sources/CodexBarCLI/CLIServeProviderIcons.swift"), encoding: .utf8)
        #expect(cli.contains("\"ProviderIcon-replicate\": \"\(Data(svg.utf8).base64EncodedString())\""))
    }

    @Test
    func `devin uses the official hexagonal mark across app website and serve`() throws {
        let root = try Self.repoRoot()
        let svg = try String(
            contentsOf: root.appending(path: "Sources/CodexBar/Resources/ProviderIcon-devin.svg"),
            encoding: .utf8)
        #expect(svg.contains("fill=\"currentColor\""))
        #expect(svg.contains("viewBox=\"0 0 128 128\""))
        #expect(svg.contains("M23 48.6315V29.1756C23 28.3205"))
        #expect(!svg.contains("<rect"))
        #expect(!svg.contains("M12 2.25c1.18 0 2.18.76"))
        let website = try String(contentsOf: root.appending(path: "docs/logos/devin.svg"), encoding: .utf8)
        #expect(website == svg)
        let cli = try String(
            contentsOf: root.appending(path: "Sources/CodexBarCLI/CLIServeProviderIcons.swift"), encoding: .utf8)
        #expect(cli.contains("\"ProviderIcon-devin\": \"\(Data(svg.utf8).base64EncodedString())\""))

        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }
        let image = try #require(ProviderBrandIcon.image(for: .devin))
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.isTemplate)
    }

    @Test
    func `pi provider icon is a transparent vector template`() throws {
        let root = try Self.repoRoot()
        let resourceURL = root
            .appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)
            .appending(path: "ProviderIcon-pi.svg")
        let svg = try String(contentsOf: resourceURL, encoding: .utf8)

        #expect(!svg.contains("<text"))
        #expect(!svg.contains("<circle"))
        #expect(svg.contains("fill=\"currentColor\""))
        #expect(svg.contains("viewBox=\"0 0 560 560\""))
        for path in [
            "M420 280H280V140H0V0H420V280Z",
            "M560 560H420V280H560V560Z",
            "M140 560H0V140H140V280H280V420H140V560Z",
        ] {
            #expect(svg.contains("d=\"\(path)\""))
        }
        let website = try String(contentsOf: root.appending(path: "docs/logos/pi.svg"), encoding: .utf8)
        #expect(website == svg)
        let cli = try String(
            contentsOf: root.appending(path: "Sources/CodexBarCLI/CLIServeProviderIcons.swift"), encoding: .utf8)
        #expect(cli.contains("\"ProviderIcon-pi\": \"\(Data(svg.utf8).base64EncodedString())\""))

        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }
        let image = try #require(ProviderBrandIcon.image(for: .pi))
        #expect(image.isTemplate)

        if let proofPath = ProcessInfo.processInfo.environment["CODEXBAR_PI_ICON_PROOF"] {
            let proof = NSImage(size: NSSize(width: 256, height: 128), flipped: false) { _ in
                for (index, background) in [NSColor.white, .black].enumerated() {
                    let tile = NSRect(x: index * 128, y: 0, width: 128, height: 128)
                    background.setFill()
                    tile.fill()
                    let glyph = NSImage(size: tile.size, flipped: false) { rect in
                        image.draw(in: rect.insetBy(dx: 24, dy: 24))
                        (index == 0 ? NSColor.black : .white).setFill()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    glyph.draw(in: tile)
                }
                return true
            }
            let data = try #require(proof.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: proofPath))
        }

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 16, height: 16))
        image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()

        var visiblePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide
                where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
            {
                visiblePixels += 1
            }
        }
        #expect(visiblePixels > 20)
        #expect(visiblePixels < 180)
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
