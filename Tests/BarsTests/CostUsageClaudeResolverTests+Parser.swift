import Foundation
import Testing
@testable import BarsCore

extension CostUsageClaudeResolverTests {
    @Test
    func `raw dated parsing and stored report identity retain distinct catalog prices`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let catalog = try Self.catalog()
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: day, cacheRoot: env.cacheRoot))
        let rawModels = ["claude-sonnet-4-5-20250929", "claude-sonnet-4-5"]
        let file = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: env.jsonl(
            rawModels.map { model in
                ["type": "assistant", "timestamp": env.isoString(for: day), "message": [
                    "model": model, "usage": ["input_tokens": 100, "output_tokens": 0],
                ]]
            }))
        let options = CostUsageScanner.Options(claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot)
        let work = CostUsageScanner.ClaudeScanWorkRecorder()
        let report = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(work) {
            try CostUsageScanner.loadDailyReportCancellable(
                provider: .claude, since: day, until: day, now: day, options: options, checkCancellation: nil)
        }
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot).usage
        #expect(cache.files.count == 1)
        let cachedPath = try #require(cache.files.keys.first)
        #expect(URL(fileURLWithPath: cachedPath).resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        let rows = try #require(cache.files[cachedPath]?.claudeRows)
        #expect(rows.map(\.model) == ["claude-sonnet-4-5", "claude-sonnet-4-5"])
        #expect(rows.map(\.costNanos) == rawModels.map {
            Int(((Self.scalar(catalog, model: $0) ?? 0) * 1_000_000_000).rounded())
        })
        #expect(rows[0].costNanos != rows[1].costNanos)
        #expect(report.summary?.totalCostUSD == Self.scalar(catalog, model: rawModels[1]).map { $0 + $0 })
        #expect(work.snapshot().catalogModelLookups == 2)
        #expect(work.snapshot().normalizationCacheMisses == 2)
        #expect(work.snapshot().repricedRows == 2)
    }
}
