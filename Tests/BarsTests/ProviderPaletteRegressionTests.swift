import BarsCore
import Foundation
import Testing

struct ProviderPaletteRegressionTests {
    struct Palette: Sendable {
        let provider: UsageProvider
        let old: UInt32
        let final: UInt32
        let widget: UInt32

        init(_ provider: UsageProvider, _ old: UInt32, _ final: UInt32, _ widget: UInt32) {
            self.provider = provider
            self.old = old
            self.final = final
            self.widget = widget
        }
    }

    static let palettes: [Palette] = [
        .init(.deepseek, 0x527DF0, 0x4D6BFE, 0x4D6BFE),
        .init(.devin, 0x46B482, 0x317CFF, 0x317CFF),
        .init(.opencode, 0x3B82F6, 0x3B82F6, 0x3B82F6),
    ]

    @Test(arguments: Self.palettes)
    func `audited menu and widget colors match their intended palettes`(_ palette: Palette) {
        let branding = ProviderDescriptorRegistry.descriptor(for: palette.provider).branding
        #expect(branding.color == ProviderColor(hex: palette.final))
        #expect(branding.widgetColor.hexString == ProviderColor(hex: palette.widget).hexString)
    }

    @Test(arguments: Self.palettes)
    func `palette does not introduce material light or dark contrast regressions`(_ palette: Palette) {
        let color = ProviderDescriptorRegistry.descriptor(for: palette.provider).branding.color
        let old = ProviderColor(hex: palette.old)
        // Controlled menu/card surfaces, not a certification of all translucent desktop backgrounds.
        for background in [ProviderColor(hex: 0xFFFFFF), ProviderColor(hex: 0x222222)] {
            let current = Self.contrast(color, background)
            let previous = Self.contrast(old, background)
            #expect(current >= 3 || previous - current < 0.5)
        }
    }

    @Test(arguments: Self.palettes)
    func `website and audit table match the app accent`(_ palette: Palette) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let hex = ProviderDescriptorRegistry.descriptor(for: palette.provider).branding.color.hexString
        let index = try String(contentsOf: root.appendingPathComponent("docs/index.html"), encoding: .utf8)
        let card = try #require(index.split(separator: "\n").first {
            $0.contains("data-provider=\"\(palette.provider.rawValue)\"")
        })
        #expect(card.contains("--brand:\(hex)"))

        let audit = try String(contentsOf: root.appendingPathComponent("docs/provider-palette.md"), encoding: .utf8)
        let row = try #require(audit.split(separator: "\n").first {
            $0.hasPrefix("| \(palette.provider.rawValue) |")
        })
        #expect(row.split(separator: "|")[3].trimmingCharacters(in: .whitespaces) == "`\(hex)`")

        let social = try String(contentsOf: root.appendingPathComponent("docs/social.html"), encoding: .utf8)
        let name = palette.provider == .deepseek ? "DeepSeek" : ProviderDefaults.metadata[palette.provider]?.displayName
        if let name, let tile = social.split(separator: "\n").first(where: {
            $0.contains("<div class=\"name\">\(name)</div>")
        }) {
            #expect(tile.contains("--brand:\(hex)"))
        }
    }

    private static func contrast(_ color: ProviderColor, _ background: ProviderColor) -> Double {
        let foreground = Self.luminance(color)
        let backdrop = Self.luminance(background)
        return (max(foreground, backdrop) + 0.05) / (min(foreground, backdrop) + 0.05)
    }

    private static func luminance(_ color: ProviderColor) -> Double {
        let linear = [color.red, color.green, color.blue].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
