import Foundation
import Testing
@testable import BarsCore

struct CostUsageTurnPerformanceTests {
    @Test
    func `summaries weight elapsed time and calculate a median without overflow`() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let one = try #require(CostUsageTurnPerformanceSample(
            completedAt: date,
            outputTokens: 100,
            durationMilliseconds: 1000,
            firstTokenMilliseconds: 200))
        let two = try #require(CostUsageTurnPerformanceSample(
            completedAt: date,
            outputTokens: 100,
            durationMilliseconds: 9000,
            firstTokenMilliseconds: 800))
        let summary = try #require(CostUsageTurnPerformanceSummary(samples: [one, two]))
        #expect(summary.outputTokensPerSecond == 20)
        #expect(summary.medianFirstTokenMilliseconds == 500)
        #expect(summary.medianDurationMilliseconds == 5000)
        #expect(summary.firstTokenSampleCount == 2)
        #expect(CostUsageTurnPerformanceSummary(samples: []) == nil)
        let huge = try #require(CostUsageTurnPerformanceSample(
            completedAt: date,
            outputTokens: Int.max,
            durationMilliseconds: Int.max))
        #expect(CostUsageTurnPerformanceSummary(samples: [huge, huge]) == nil)
    }

    @Test
    func `turn duration is the median rather than the mean or an individual turn`() throws {
        let samples = try [9000, 1000, 2000].map { duration in
            try #require(CostUsageTurnPerformanceSample(
                completedAt: Date(timeIntervalSince1970: 1000),
                outputTokens: 100,
                durationMilliseconds: duration))
        }
        let summary = try #require(CostUsageTurnPerformanceSummary(samples: samples))
        #expect(summary.medianDurationMilliseconds == 2000)
        #expect(summary.outputTokensPerSecond == 25)
        #expect(summary.medianFirstTokenMilliseconds == nil)
        let huge = try #require(CostUsageTurnPerformanceSample(
            completedAt: Date(timeIntervalSince1970: 1000),
            outputTokens: 0,
            durationMilliseconds: Int.max))
        #expect(CostUsageTurnPerformanceSummary(samples: [huge])?.medianDurationMilliseconds == Double(Int.max))
    }
}
