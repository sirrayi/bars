import CodexBarCore
import Foundation
import SwiftUI
import Testing
import WidgetKit
@testable import CodexBarWidget

@Suite("Widget provider pager")
struct WidgetProviderPagerTests {
    private let providers: [UsageProvider] = [.opencodego, .claude, .opencode, .devin, .deepseek]

    // MARK: - Paging

    @Test
    func `a single provider is not pageable`() {
        let pager = ProviderPager.make(providers: [.opencodego], selected: .opencodego)

        #expect(pager?.isPageable == false)
        #expect(pager?.positionText == "1/1")
    }

    @Test
    func `an unknown selection falls back to the first provider`() {
        let pager = ProviderPager.make(providers: [.opencodego, .claude], selected: .deepseek)

        #expect(pager?.selected == .opencodego)
        #expect(pager?.position == 1)
    }

    @Test
    func `an empty provider list has no pager`() {
        #expect(ProviderPager.make(providers: [], selected: .opencodego) == nil)
    }

    @Test
    func `paging visits every provider exactly once before returning`() {
        var seen: [UsageProvider] = []
        var current = self.providers[0]
        for _ in self.providers.indices {
            seen.append(current)
            current = ProviderPager.make(providers: self.providers, selected: current)?.next ?? current
        }

        #expect(seen == self.providers)
        #expect(current == self.providers[0])
    }

    // MARK: - Marks

    @Test
    func `uncurated providers fall back to derived initials`() {
        #expect(ProviderMonogram.derived(from: "Token Plan") == "TP")
        #expect(ProviderMonogram.derived(from: "Warp") == "WA")
        #expect(ProviderMonogram.derived(from: "z.ai / GLM") == "ZA")
        #expect(ProviderMonogram.derived(from: "X") == "XX")
        #expect(ProviderMonogram.derived(from: "") == "?")
    }

    @Test
    func `every provider has a mark`() {
        for provider in UsageProvider.allCases {
            #expect(!ProviderMonogram.text(for: provider).isEmpty)
        }
    }

    // MARK: - Titles

    @Test
    func `small tiles preserve the provider name`() {
        for provider in UsageProvider.allCases where ProviderChoice(provider: provider) != nil {
            let title = ProviderTitle.text(for: provider, size: .small)
            #expect(title == ProviderTitle.text(for: provider, size: .large))
        }
    }

    // MARK: - Unavailable metrics

    @Test
    func `a metric a provider never reports explains itself instead of showing a bare dash`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let display = CompactMetricFormatter.display(for: entry, metric: .credits)

        #expect(display.value == WidgetFormat.unavailable)
        #expect(CompactMetricFormatter
            .unavailableDetail(value: display.value, entry: entry) == "Not reported by Claude")
    }

    @Test
    func `a reported metric carries no unavailable note`() {
        #expect(CompactMetricFormatter.unavailableDetail(
            value: "1,243.4",
            entry: WidgetSnapshot.ProviderEntry(
                provider: .opencodego,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                primary: nil,
                secondary: nil,
                tertiary: nil,
                creditsRemaining: 1243.4,
                codeReviewRemainingPercent: nil,
                tokenUsage: nil,
                dailyUsage: [])) == nil)
    }

    // MARK: - Tinted and clear appearances

    @Test
    func `outside full colour the mark inverts so the monogram survives the luminance mask`() {
        // Desktop widgets in tinted/clear render through a luminance mask. A brand fill carrying a
        // dark label collapses to an empty white square, which is what shipped first.
        for mode in [WidgetRenderingMode.vibrant, .accented] {
            let selected = ProviderMarkStyle.resolve(renderingMode: mode, provider: .claude, isSelected: true)
            let unselected = ProviderMarkStyle.resolve(renderingMode: mode, provider: .claude, isSelected: false)

            #expect(selected.foreground == Color.primary)
            #expect(selected.background != Color.primary)
            #expect(unselected.foreground != unselected.background)
        }
    }

    @Test
    func `full colour keeps the brand fill and its contrast picked label`() {
        let style = ProviderMarkStyle.resolve(renderingMode: .fullColor, provider: .claude, isSelected: true)

        #expect(style.background == WidgetColors.color(for: ProviderInstanceID.claude))
        #expect(style.foreground == .black)
    }

    // MARK: - Contrast

    @Test
    func `every provider mark label is the higher contrast choice`() {
        for provider in UsageProvider.allCases {
            guard let color = ProviderBrandColor.resolve(for: provider.instanceID) else { continue }
            let luminance = WidgetContrast.relativeLuminance(of: color)
            let whiteContrast = 1.05 / (luminance + 0.05)
            let blackContrast = (luminance + 0.05) / 0.05
            let expected = blackContrast >= whiteContrast ? "black" : "white"
            let actual = WidgetContrast.label(on: color) == .black ? "black" : "white"

            #expect(actual == expected, "\(provider.rawValue) picked \(actual)")
        }
    }
}
