import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Bars
@testable import BarsCore

@MainActor
struct SpendToolActivityTests {
    @Test
    func `filters outcomes privacy and duration labels preserve native semantics`() throws {
        let snapshot = try Self.snapshot()
        let operations = snapshot.operations
        #expect(operations.filter(SpendToolActivityFilter.attention.includes).count == 2)
        #expect(operations.filter(SpendToolActivityFilter.slow.includes).count == 2)
        BarsLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect(spendToolOperationName(operations[1], hidePersonalInfo: false) ==
                "example/search")
            #expect(spendToolOperationName(operations[1], hidePersonalInfo: true) == "MCP 工具")
            #expect(spendToolOutcome(operations[2]) == "退出码 1")
            #expect(spendToolDuration(operations[0]) == "12.5 秒")
            #expect(spendToolDuration(operations[2]) == "32 毫秒")
            #expect(spendToolDuration(operations[3]) == "—")
        }
    }

    @Test
    func `render production tool activity with synthetic operations`() throws {
        guard let path = ProcessInfo.processInfo.environment["BARS_TOOL_UI_PROOF_DIR"]
        else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshot = try Self.snapshot()
        let sample = try #require(CostUsageTurnPerformanceSample(
            completedAt: Date(),
            outputTokens: 200,
            durationMilliseconds: 15000,

            firstTokenMilliseconds: 650,
            model: "gpt-5.4"))
        let performance = try #require(CostUsageTurnPerformanceSummary(samples: [sample]))
        for language in ["en", "zh-Hans"] {
            for dark in [false, true] {
                for width in [360.0, 820.0] {
                    for filter in SpendToolActivityFilter.allCases {
                        try BarsLocalizationOverride.$appLanguage.withValue(language) {
                            let view = VStack(alignment: .leading, spacing: 16) {
                                Text(L("Usage & Spend")).font(.title2.bold())
                                Text(L("Sessions")).font(.headline)
                                Text("Example project · Check build").font(.body.weight(.medium))
                                SpendSessionPerformanceView(summary: performance)
                                Divider()
                                Text(L("spend_tools_title")).font(.subheadline.weight(.semibold))
                                SpendToolActivityContent(
                                    snapshot: snapshot,
                                    range: nil,
                                    hidePersonalInfo: false,

                                    filter: filter)
                                Text(L("spend_tools_scope")).font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(20).frame(width: width)
                            .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : .white)
                            .foregroundStyle(dark ? .white : .black)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            let renderer = ImageRenderer(content: view)
                            renderer.scale = 2
                            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
                            let bytes = try #require(bitmap.representation(
                                using: .png,
                                properties: [:]))
                            try bytes.write(to: root.appendingPathComponent(
                                "tools-\(language)-\(dark ? "dark" : "light")-\(Int(width))-\(filter.rawValue).png"))
                        }
                    }
                }
            }
        }
    }

    private static func snapshot() throws -> SessionToolActivitySnapshot {
        let now = try #require(CostUsageScanner.dateFromTimestamp("2026-05-10T12:00:00Z"))
        let operations = [
            SessionToolOperation(
                id: .init(threadID: "example", turnID: "turn", itemID: "build"),
                kind: .command,
                name: "CommandExecution",
                preview: "swift build",
                completedAt: now,

                outcome: .completed,
                exitCode: 0,
                durationMilliseconds: 12500,
                timing: .native,

                recordOffset: 0,
                recordLength: 1),
            SessionToolOperation(
                id: .init(threadID: "example", turnID: "turn", itemID: "search"),
                kind: .mcp,
                name: "example/search",
                preview: nil,

                completedAt: now.addingTimeInterval(-20),
                outcome: .toolError,
                exitCode: nil,
                durationMilliseconds: 1100,
                timing: .native,

                recordOffset: 1,
                recordLength: 1),
            SessionToolOperation(
                id: .init(threadID: "example", turnID: "turn", itemID: "command"),
                kind: .command,
                name: "CommandExecution",
                preview: "rg example Sources",

                completedAt: now.addingTimeInterval(-40),
                outcome: .nonzeroExit,
                exitCode: 1,
                durationMilliseconds: 32,
                timing: .native,

                recordOffset: 2,
                recordLength: 1),
            SessionToolOperation(
                id: .init(threadID: "example", turnID: "turn", itemID: "patch"),
                kind: .fileChange,
                name: "FileChange",
                preview: nil,

                completedAt: now.addingTimeInterval(-60),
                outcome: .completed,
                exitCode: nil,
                durationMilliseconds: nil,
                timing: nil,

                recordOffset: 3,
                recordLength: 1),
            SessionToolOperation(
                id: .init(threadID: "example", turnID: "turn", itemID: "web"),
                kind: .webSearch,
                name: "WebSearch",
                preview: nil,

                completedAt: now.addingTimeInterval(-80),
                outcome: .unknown,
                exitCode: nil,
                durationMilliseconds: 14000,

                timing: .recordedInterval,
                recordOffset: 4,
                recordLength: 1),
        ]
        return SessionToolActivitySnapshot(
            source: .init(
                fileURL: URL(fileURLWithPath: "/synthetic/rollout.jsonl"),
                sessionID: "example"),
            operations: operations,
            ignoredRecordCount: 0,
            isPartial: false,

            fileSize: 5,
            modificationDate: now,
            fileNumber: 0)
    }
}
