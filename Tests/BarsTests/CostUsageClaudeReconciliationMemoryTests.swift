import CryptoKit
import Foundation
import Testing
@testable import BarsCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageClaudeReconciliationMemoryTests {
    @Test
    func `winner payload contains only two indexes`() {
        let priorStride = MemoryLayout<(path: String, row: CostUsageScanner.ClaudeUsageRow)>.stride
        #expect(CostUsageScanner.claudeWinnerPayloadStride == 2 * MemoryLayout<Int>.stride)
        #expect(CostUsageScanner.claudeWinnerPayloadStride * 10 < priorStride)
    }

    /// Golden bytes captured from the row-copy implementation, including both temporal projections.
    @Test(arguments: 0..<4)
    func `randomized duplicate order preserves exact output`(seed: Int) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var generator = Generator(state: UInt64(seed))
        var cache = CostUsageClaudeRebuildTests.cache(fileCount: 64, rowsPerFile: 50, includeOverflow: true)
        let files = cache.files.sorted { $0.key < $1.key }.shuffled(using: &generator)
        cache.files = [:]
        for (path, var file) in files {
            file.claudeRows?.shuffle(using: &generator)
            cache.files[path] = file
        }
        cache.files["empty"] = .init(mtimeUnixMs: 0, size: 0, days: [:], claudeRows: [])
        let rows = CostUsageScanner.reconciledClaudeRows(cache: cache)
        CostUsageScanner.rebuildClaudeDays(cache: &cache, rows: rows)
        let report = CostUsageScanner.buildClaudeReportFromCache(
            cache: cache,
            range: CostUsageClaudeRebuildTests.range,
            now: CostUsageClaudeRebuildTests.now,
            modelsDevCacheRoot: env.cacheRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try [
            encoder.encode(rows), encoder.encode(cache.days), encoder.encode(report),
            encoder.encode(report.hourly.map(CostUsageCachedReport.HourlyEntry.init)),
            encoder.encode(report.quotaSlices.map(CostUsageCachedReport.QuotaSlice.init)),
        ]
        let digest = try SHA256.hash(data: encoder.encode(bytes)).map { String(format: "%02x", $0) }.joined()
        let expected = [
            "08789f525e802b91687608e13f3b731a4132c43fb5166dfc93122e3a833fc374",
            "b1ca07316ec993878365e09d19b47832f00da4b6dc25f61bfe67dcebee05d0f3",
            "5ad401213869a13b631e5e12989459e24784416e69520bcc5a0f91a8b7492c1a",
            "8eedb7a06bd1afa48ebc6e8c485e4ad51649496a7c9f3df1bc172a8b71336abb",
        ]
        #expect(digest == expected[seed])
        #expect(cache.days["2026-09-01"]?["fixture/overflow"] == nil)
    }

    @Test
    func `cancellation after reconciliation leaves the cache and memo intact`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = CostUsageClaudeRebuildTests.now
        _ = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: """
        {"type":"assistant","timestamp":"2026-09-30T12:00:00Z","requestId":"fixture-request",
        "message":{"id":"fixture-message","model":"claude-sonnet-4-6",
        "usage":{"input_tokens":10,"output_tokens":1}}}
        """.replacingOccurrences(of: "\n", with: "") + "\n")
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            calendar: CostUsageClaudeRebuildTests.range.calendar)
        options.refreshMinIntervalSeconds = 0
        let prior = try CostUsageScanner.loadDailyReportCancellable(
            provider: .claude, since: now, until: now, now: now, options: options, checkCancellation: nil)
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: env.cacheRoot)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: cacheURL)
        let before = try [Data(contentsOf: cacheURL), Data(contentsOf: memoURL)]
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        options.forceRescan = true
        #expect(throws: CancellationError.self) {
            try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                _ = try CostUsageScanner.loadDailyReportCancellable(
                    provider: .claude,
                    since: now,
                    until: now,
                    now: now,
                    options: options,
                    checkCancellation: {
                        if recorder.snapshot().reconciliations > 0 { throw CancellationError() }
                    })
            }
        }
        #expect(recorder.snapshot().reconciliations == 1)
        #expect(try [Data(contentsOf: cacheURL), Data(contentsOf: memoURL)] == before)
        options.forceRescan = false
        let after = try CostUsageScanner.loadDailyReportCancellable(
            provider: .claude, since: now, until: now, now: now, options: options, checkCancellation: nil)
        #expect(after.data == prior.data)
        #expect(after.summary == prior.summary)
        #expect(after.hourly == prior.hourly)
        #expect(after.quotaSlices == prior.quotaSlices)
    }

    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            self.state = self.state &* 6_364_136_223_846_793_005 &+ 1
            return self.state
        }
    }
}
