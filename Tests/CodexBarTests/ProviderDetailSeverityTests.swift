import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

struct ProviderDetailSeverityTests {
    @MainActor
    @Test
    func `detail bars render independent severity colors and retain the legacy tint`() throws {
        let severities: [ProviderDetailSection.Row.Severity?] = [.normal, .warning, .critical, nil]
        let rows = try severities.enumerated().map { index, severity in
            try ProviderDetailSection.Row(
                label: "Pool \(index)", value: "1 / 1", progress: .init(used: 1, total: 1), severity: severity)
        }
        let section = try ProviderDetailSection(rows: rows)
        let renderer = ImageRenderer(content: ProviderDetailSectionsContent(sections: [section], chartColor: .blue)
            .frame(width: 280).padding(12).background(.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        var counts = [0, 0, 0, 0]
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else {
                    continue
                }
                let r = color.redComponent
                let g = color.greenComponent
                let b = color.blueComponent
                if r < 0.5, g > 0.45, b < 0.5 { counts[0] += 1 }
                if r > 0.65, g > 0.35, g < 0.8, b < 0.35 { counts[1] += 1 }
                if r > 0.65, g < 0.35, b < 0.35 { counts[2] += 1 }
                if r < 0.4, b > 0.6 { counts[3] += 1 }
            }
        }
        // Each full bar covers thousands of pixels; a small status glyph alone cannot satisfy this.
        #expect(counts.allSatisfy { $0 > 1000 }, "Expected green/orange/red/legacy blue bars: \(counts)")
    }
}
