import AppKit
import BarsCore
import Testing
@testable import Bars

@MainActor
@Suite(.serialized)
struct IconRendererHideCrittersTests {
    private func pixels(_ image: NSImage) throws -> Data {
        try #require(image.tiffRepresentation)
    }

    private func icon(style: IconStyle, weeklyRemaining: Double? = 40, hideCritters: Bool) -> NSImage {
        IconRenderer.makeIcon(
            primaryRemaining: 60,
            weeklyRemaining: weeklyRemaining,
            creditsRemaining: nil,
            stale: false,
            style: style,
            hideCritters: hideCritters)
    }

    @Test(arguments: [
        IconStyle.claude,
    ])
    func `hiding critters removes every decorated style twist`(style: IconStyle) throws {
        let decorated = self.icon(style: style, hideCritters: false)
        let plain = self.icon(style: style, hideCritters: true)

        #expect(try self.pixels(decorated) != self.pixels(plain))
    }

    @Test
    func `fill width tracks and clamps the reported percentage`() {
        #expect(IconRenderer.fillWidthPixels(remaining: 46, rectWidth: 30) == 14)
        #expect(IconRenderer.fillWidthPixels(remaining: -1, rectWidth: 30) == 0)
        #expect(IconRenderer.fillWidthPixels(remaining: 0, rectWidth: 30) == 0)
        #expect(IconRenderer.fillWidthPixels(remaining: 100, rectWidth: 30) == 30)
        #expect(IconRenderer.fillWidthPixels(remaining: 120, rectWidth: 30) == 30)
    }

    @Test
    func `single quota layout follows provider policy even in combined style`() throws {
        func image(
            primary: Double?,
            weekly: Double?,
            policy: IconRenderer.QuotaLayoutPolicy) -> NSImage
        {
            IconRenderer.makeIcon(
                primaryRemaining: primary,
                weeklyRemaining: weekly,
                creditsRemaining: nil,
                stale: false,
                style: .combined,
                hideCritters: true,
                quotaLayoutPolicy: policy)
        }

        let compact = IconRenderer.QuotaLayoutPolicy.provider(.opencode)
        let reserved = IconRenderer.QuotaLayoutPolicy.provider(.claude)
        let compactPrimary = image(primary: 46, weekly: nil, policy: compact)
        let compactSecondary = image(primary: nil, weekly: 46, policy: compact)
        let reservedPrimary = image(primary: 46, weekly: nil, policy: reserved)

        #expect(try self.pixels(compactPrimary) == self.pixels(compactSecondary))
        #expect(try self.pixels(compactPrimary) != self.pixels(reservedPrimary))
    }

    @Test
    func `morph icon honors hide critters at full progress`() throws {
        // At full progress the morph cross-fades into the bar icon, which carries
        // the Claude critter. A distinct cache key must keep the two renders separate.
        let decorated = IconRenderer.makeMorphIcon(progress: 1, style: .claude, hideCritters: false)
        let plain = IconRenderer.makeMorphIcon(progress: 1, style: .claude, hideCritters: true)

        #expect(try self.pixels(decorated) != self.pixels(plain))
    }
}
