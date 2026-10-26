import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MenuBarLayoutThroughputTests {
    @Test
    func `the v4 generation stays readable and the newer layout and rules win on load`() throws {
        let decoder = JSONDecoder()
        let layout = MenuBarLayout(lines: [[.icon, .tokensPerMinute, .tokensSparkline, .costToday]])
        let blobs = try MenuBarLayoutPersistence.encoded(layout)
        let restored = try MenuBarLayoutPersistence.preferredLayout(
            current: decoder.decode(MenuBarLayout.self, from: blobs.current),
            v4: decoder.decode(MenuBarLayout.self, from: blobs.v4),
            v3: decoder.decode(MenuBarLayout.self, from: blobs.v3),
            released: decoder.decode(MenuBarLayout.self, from: blobs.released),
            legacy: decoder.decode(MenuBarLayout.self, from: blobs.legacy))
        #expect(restored == layout)

        var library = MenuBarLayoutConditional.shippedLibrary()
        library[0].thenToken = .tokensPerMinute
        library[0].elseToken = .tokensSparkline
        let rules = try MenuBarLayoutPersistence.encodedLibrary(library)
        let v4Text = try #require(String(data: rules.v4, encoding: .utf8))
        #expect(!v4Text.contains("tokensPerMinute"))
        #expect(!v4Text.contains("tokensSparkline"))
        let v4Rules = try decoder.decode([MenuBarLayoutConditional].self, from: rules.v4)
        #expect(v4Rules[0].thenToken == .hidden)
        #expect(v4Rules[0].elseToken == .hidden)
        let restoredRules = try MenuBarLayoutPersistence.preferredLibrary(
            current: decoder.decode([MenuBarLayoutConditional].self, from: rules.current),
            v5: decoder.decode([MenuBarLayoutConditional].self, from: rules.v5),
            v4: v4Rules,
            v3: decoder.decode([MenuBarLayoutConditional].self, from: rules.v3),
            released: decoder.decode([MenuBarLayoutConditional].self, from: rules.released),
            legacy: decoder.decode([MenuBarLayoutConditional].self, from: rules.legacy))
        #expect(restoredRules == library)
    }

    @Test
    func `sparkline buckets preserve peaks and stop at the reporting frontier`() {
        let minutes: [ProviderThroughputSnapshot.Minute] = (0..<60).map { (index: Int) in
            let totalTokens: Int = index == 41 ? 151_000_000 : index == 56 ? 49_000_000 : index * 1_000_000
            return ProviderThroughputSnapshot.Minute(
                start: Date(timeIntervalSince1970: Double(index * 60)),
                totalTokens: totalTokens,
                requests: 50,
                isPending: index >= 57)
        }
        let graph = MenuBarTokensSparkline(minutes: minutes)
        #expect(graph.values.count == 18)
        #expect(graph.values.max() == 151_000_000)
        #expect(graph.latest == 49_000_000)
        #expect(graph.values.first == 2_000_000)
        #expect(graph.values.last == 55_000_000)
        #expect(graph == MenuBarTokensSparkline(minutes: Array(minutes.prefix(57))))
        #expect(MenuBarTokensSparkline(minutes: Array(minutes.suffix(3))).values.isEmpty)
        #expect(MenuBarTokensSparkline(minutes: []).values.isEmpty)
        let single = MenuBarTokensSparkline(minutes: Array(minutes.prefix(1)))
        #expect(single.values == [0])
        #expect(single.latest == 0)
        #expect(MenuBarTokensSparkline(minutes: minutes, columnCount: 0).values == [151_000_000])
    }
}
