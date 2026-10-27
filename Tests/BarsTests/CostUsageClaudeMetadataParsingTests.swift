import Foundation
import Testing
@testable import BarsCore

struct CostUsageClaudeMetadataParsingTests {
    @Test
    func `JSONSerialization rejection and trailing comma acceptance preserve bytes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 29)
        let valid = """
        {"type":"assistant","timestamp":"\(env
            .isoString(for: day))","message":{"model":"claude-test-unknown","usage":{"input_tokens":2,}}}
        """
        let malformed = [
            #"{"type":"assistant","usage":NaN}"#,
            #"{"type":"assistant","usage":"\uD800"}"#,
            #"{"type":"assistant","usage":null"#,
            #"{"type":"assistant","usage":null} trailing"#,
        ]
        for raw in malformed {
            #expect((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) == nil)
        }
        #expect(try JSONSerialization.jsonObject(with: Data(valid.utf8)) is NSDictionary)
        let rejectedRoots = ["[\(valid)]", "[]", "null", "2", #"{"type":"assistant","usage":null}"#]
        let content = (malformed + rejectedRoots + [valid]).joined(separator: "\n") + "\n"
        let file = try env.writeClaudeProjectFile(relativePath: "project/malformed.jsonl", contents: content)
        for filter: CostUsageScanner.ClaudeLogProviderFilter in [.all, .excludeVertexAI, .vertexAIOnly] {
            let parsed = CostUsageScanner.parseClaudeFile(
                fileURL: file,
                range: .init(since: day, until: day),
                providerFilter: filter,
                modelsDevCatalog: ModelsDevCatalog(providers: [:]))
            #expect(parsed.rows.count == (filter == .vertexAIOnly ? 0 : 1))
            #expect(parsed.rows.allSatisfy { $0.input == 2 && $0.model == "claude-test-unknown" })
            #expect(parsed.parsedBytes == Int64(content.utf8.count))
        }
    }
}
