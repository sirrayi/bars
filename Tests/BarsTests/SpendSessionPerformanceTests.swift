import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Bars
@testable import BarsCore

@MainActor
struct SpendSessionPerformanceTests {
    @Test
    func `metrics describe whole turn throughput and keep missing first token timing unavailable`() throws {
        let sample = try #require(CostUsageTurnPerformanceSample(
            completedAt: Date(),
            outputTokens: 20,
            durationMilliseconds: 10000))
        let summary = try #require(CostUsageTurnPerformanceSummary(samples: [sample]))
        BarsLocalizationOverride.$appLanguage.withValue("en") {
            let metrics = spendSessionPerformanceMetrics(summary)
            #expect(metrics.map(\.value) == ["—", "2.0 tok/s", "10.0 s", "—"])
            #expect(metrics[0].note == "First-token samples: 0 / 1")
            #expect(metrics[3].note == "0 / 1 turns with cache data")
        }
        BarsLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            let metrics = spendSessionPerformanceMetrics(summary)
            #expect(metrics.map(\.value) == ["—", "2.0 tok/s", "10.0 秒", "—"])
        }
    }

    @Test
    func `details retain unavailable values and sample coverage`() throws {
        let sample = try #require(CostUsageTurnPerformanceSample(
            completedAt: Date(),
            outputTokens: 100,
            durationMilliseconds: 1000,
            inputTokens: 100,
            cachedInputTokens: 80))
        let summary = try #require(CostUsageTurnPerformanceSummary(samples: [sample]))
        BarsLocalizationOverride.$appLanguage.withValue("en") {
            let metrics = spendSessionPerformanceDetailMetrics(summary)
            #expect(metrics[0].value == "—")
            #expect(metrics[0].note != nil)
            #expect(metrics[1].value == "—")
            #expect(metrics[1].note != nil)
            let cachedInput = spendSessionPerformanceMetrics(summary).first { $0.id == "cached-input" }
            #expect(cachedInput?.value == "80.0%")
            #expect(cachedInput?.note == "1 / 1 turns with cache data")
            #expect(summary.firstTokenSampleCount == 0)
            #expect(summary.sampleCount == 1)
            #expect(summary.details.cacheSampleCount == 1)
        }
    }

    @Test
    func `primary observations distinguish measured zero cache reuse from missing records`() throws {
        let measured = try #require(CostUsageTurnPerformanceSample(
            completedAt: Date(),
            outputTokens: 300,
            durationMilliseconds: 1000,
            firstTokenMilliseconds: 100,
            inputTokens: 1000,
            cachedInputTokens: 0))
        let unrecorded = try #require(CostUsageTurnPerformanceSample(
            completedAt: Date(),
            outputTokens: 200,
            durationMilliseconds: 2000))
        let summary = try #require(CostUsageTurnPerformanceSummary(samples: [measured, unrecorded]))
        BarsLocalizationOverride.$appLanguage.withValue("en") {
            let metrics = spendSessionPerformanceMetrics(summary)
            #expect(metrics.map(\.value) == ["0.1 s", "166.7 tok/s", "1.5 s", "0.0%"])
            #expect(metrics[0].note == "First-token samples: 1 / 2")
            #expect(metrics.first(where: { $0.id == "cached-input" })?.note == "1 / 2 turns with cache data")
            #expect(!spendSessionPerformanceDetailMetrics(summary).contains { $0.id == "cached-input" })
        }
    }
}
