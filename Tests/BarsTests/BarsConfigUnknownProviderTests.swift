import Foundation
import Testing
@testable import Bars
@testable import BarsCore

struct BarsConfigUnknownProviderTests {
    @Test
    func `removed provider entries do not invalidate persisted config`() throws {
        let data = Data(#"""
        {
          "version": 1,
          "providers": [
            {"id": "kimik2", "enabled": true},
            {"id": "crossmodel", "enabled": true},
            {"id": "crof", "enabled": true, "apiKey": "retired-fixture-key"},
            {"id": "opencode", "enabled": false, "source": "oauth"}
          ]
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(BarsConfig.self, from: data)

        #expect(decoded.providers.map(\.id) == [.opencode])
        #expect(decoded.providerConfig(for: .opencode)?.enabled == false)
        #expect(decoded.providerConfig(for: .opencode)?.source == .oauth)
    }

    @Test
    func `removed provider id keeps retained claude and devin entries`() throws {
        let data = Data(#"""
        {
          "version": 1,
          "providers": [
            {"id": "claude", "enabled": true},
            {"id": "cursor", "enabled": true},
            {"id": "devin", "enabled": true}
          ]
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(BarsConfig.self, from: data)

        #expect(decoded.providers.map(\.id) == [.claude, .devin])
        #expect(decoded.providerConfig(for: .claude)?.enabled == true)
        #expect(decoded.providerConfig(for: .devin)?.enabled == true)
    }

    @Test
    func `reading and saving retired Crof config preserves its record`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BarsConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        let config = BarsConfig(providers: UsageProvider.allCases
            .filter { $0.rawValue != "crof" }
            .map { ProviderConfig(id: $0.instanceID, enabled: false) })
        let expected = try store.encodedData(for: config)
        let text = try #require(String(data: expected, encoding: .utf8))
        let retired = text.replacingOccurrences(
            of: "\"providers\" : [",
            with: "\"providers\" : [{\"id\":\"crof\",\"enabled\":true,\"apiKey\":\"retired-fixture-key\"},")
        let original = Data(retired.utf8)
        try store.saveEncodedData(original)

        let loaded = try #require(try store.load())

        #expect(loaded.providers.map(\.id) == config.providers.map(\.id))
        #expect(try Data(contentsOf: store.fileURL) == original)
        try store.save(loaded)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? NSDictionary)
        let originalJSON = try #require(JSONSerialization.jsonObject(with: original) as? NSDictionary)
        #expect(saved == originalJSON)
    }

    @Test
    func `unavailable plugin records survive normalization and existing file upgrades`() throws {
        let config = try BarsConfig.decode(from: Self.fixture)
        let encoded = try config.normalized().normalized().encodedData()
        try Self.expectRetainedRecords(in: encoded)
    }

    @Test
    func `opaque JSON keeps arbitrary numeric tokens and escaped strings byte for byte`() throws {
        let record = #"""
        { "id":"opaque-numbers", "enabled":true, "future":[1e400,1e-400,-0,0.123456789012345678901234567890123456789],
          "pluginSecrets":{"TOKEN":"fixture-secret"}, "text":"braces } ] and escaped \" quote \\ slash" }
        """#
        let raw = Data(#"{"nested":{"providers":[]},"provi\u0064ers":["#.utf8)
            + Data(record.utf8) + Data(#"],"version":1}"#.utf8)
        let config = try BarsConfig.decode(from: raw).normalized()
        let saved = try #require(String(data: config.encodedData(), encoding: .utf8))
        #expect(saved.contains(record))
        let redacted = try #require(String(data: config.sanitizedForDump().encodedData(), encoding: .utf8))
        #expect(!redacted.contains("fixture-secret"))
        #expect(!redacted.contains("1e400"))
        #expect(redacted.contains("[REDACTED]"))
        #expect(throws: (any Error).self) { try JSONEncoder().encode(config) }
    }

    @Test(arguments: ["first-opaque", "grok"])
    func `explicit deletion shifts remaining opaque entries with their neighbors`(_ deleted: String) throws {
        var config = try BarsConfig.decode(from: Data(#"""
        {"version":1,"providers":[{"id":"first-opaque"},{"id":"grok"},{"id":"second-opaque"},{"id":"groq"}]}
        """#.utf8))
        try config.removeProviderConfig(for: #require(ProviderInstanceID(rawValue: deleted)))
        let root = try #require(JSONSerialization.jsonObject(with: config.encodedData()) as? [String: Any])
        let records = try #require(root["providers"] as? [[String: Any]])
        let expected = ["first-opaque", "grok", "second-opaque", "groq"].filter { $0 != deleted }
        #expect(records.compactMap { $0["id"] as? String } == expected)
    }

    static let fixture = Data(#"""
    {"version":1,"providers":[
      {"id":"fixture-unavailable","enabled":true,"pluginSettings":{"scope":"fixture"},
       "pluginSecrets":{"TOKEN":"fixture-secret"},"future":{"null":null,"items":[true,42,"value"],
       "large":18446744073709551615,"fraction":0.1234567890123456789012345678}},
      {"id":"grok","enabled":false},
      {"id":"future.invalid/id","enabled":false,"source":"future-mode","pluginSecrets":{"OTHER":"fixture-other"}}
    ]}
    """#.utf8)

    static func expectRetainedRecords(in data: Data) throws {
        let original = try #require(JSONSerialization.jsonObject(with: self.fixture) as? [String: Any])
        let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let originalProviders = try #require(original["providers"] as? [NSDictionary])
        let savedProviders = try #require(saved["providers"] as? [NSDictionary])
        #expect(savedProviders.count >= 3)
        for index in [0, 2] {
            #expect(savedProviders[index] == originalProviders[index])
        }
    }
}
