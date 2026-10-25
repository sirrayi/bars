#if os(macOS)

import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct DevinLocalCostReaderTests {
    @Test
    func `request copies sharing one request id count once`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let createdAt = Int64(self.now.timeIntervalSince1970) - 60
        for _ in 0..<3 {
            try Self.insertNode(
                databaseURL: env.databaseURL,
                requestID: "req-1",
                generationModel: "swe-2-high",
                createdAt: createdAt,
                input: 100,
                output: 50)
        }
        try Self.insertNode(
            databaseURL: env.databaseURL,
            requestID: "req-2",
            generationModel: "swe-2-high",
            createdAt: createdAt,
            input: 200,
            output: 20)

        let report = try self.report(databaseURL: env.databaseURL)
        let entry = try #require(report?.data.only)
        #expect(entry.requestCount == 2)
        #expect(entry.inputTokens == 300)
        #expect(entry.outputTokens == 70)
        #expect(entry.costUSD == 0)
        #expect(entry.pricedRequestCount == 2)
    }

    @Test
    func `request first seen before the window stays excluded when recopied inside it`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Int64(self.now.timeIntervalSince1970)
        try Self.insertNode(
            databaseURL: env.databaseURL,
            requestID: "req-old",
            generationModel: "swe-2-high",
            createdAt: now - 10 * 24 * 3600,
            input: 100,
            output: 50)
        try Self.insertNode(
            databaseURL: env.databaseURL,
            requestID: "req-old",
            generationModel: "swe-2-high",
            createdAt: now - 60,
            input: 100,
            output: 50)

        let report = try self.report(
            databaseURL: env.databaseURL,
            since: self.now.addingTimeInterval(-24 * 3600))
        #expect(report?.data.isEmpty == true)
    }

    @Test
    func `claude model with effort suffix prices through the catalog`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertNode(
            databaseURL: env.databaseURL,
            requestID: "req-1",
            generationModel: "claude-opus-5-5-high",
            createdAt: Int64(self.now.timeIntervalSince1970) - 60,
            input: 10000,
            output: 5000,
            cacheRead: 100_000,
            cacheCreation: 50000)

        let report = try self.report(databaseURL: env.databaseURL)
        let entry = try #require(report?.data.only)
        // 10k in @ $4/M + 5k out @ $20/M + 100k read @ $0.20/M + 50k write @ $5/M.
        #expect(entry.costUSD.map { abs($0 - 0.41) < 0.0001 } == true)
        let breakdown = try #require(entry.modelBreakdowns?.only)
        #expect(breakdown.modelName == "claude-opus-5-5-high")
        #expect(breakdown.costUSD == entry.costUSD)
    }

    @Test(arguments: ["swe-2-high", "swe-2-max", "compactor"])
    func `promo models cost zero and count as priced`(model: String) throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertNode(
            databaseURL: env.databaseURL,
            requestID: "req-1",
            generationModel: model,
            createdAt: Int64(self.now.timeIntervalSince1970) - 60,
            input: 1000,
            output: 100)

        let report = try self.report(databaseURL: env.databaseURL)
        let entry = try #require(report?.data.only)
        #expect(entry.costUSD == 0)
        #expect(entry.pricedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 0)
    }

    @Test
    func `unrecognized model reports unpriced requests`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertNode(
            databaseURL: env.databaseURL,
            requestID: "req-1",
            generationModel: "fictional-model-x",
            createdAt: Int64(self.now.timeIntervalSince1970) - 60,
            input: 1000,
            output: 100)

        let report = try self.report(databaseURL: env.databaseURL)
        let entry = try #require(report?.data.only)
        #expect(entry.costUSD == nil)
        #expect(entry.pricedRequestCount == 0)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.modelBreakdowns?.first?.costUSD == nil)
        #expect(entry.inputTokens == 1000)
    }

    @Test
    func `custom pricing overlay overrides the free promo route`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertNode(
            databaseURL: env.databaseURL,
            requestID: "req-1",
            generationModel: "swe-2-high",
            createdAt: Int64(self.now.timeIntervalSince1970) - 60,
            input: 1000,
            output: 100)

        let customPricing = CostUsageCustomPricing.parse(Data(
            #"{"devin/swe-2-high": {"input": 10, "output": 30}}"#.utf8))
        let report = try self.report(
            databaseURL: env.databaseURL,
            customPricing: customPricing)
        let entry = try #require(report?.data.only)
        // 1k in @ $10/M + 100 out @ $30/M.
        #expect(entry.costUSD.map { abs($0 - 0.013) < 0.0001 } == true)
        #expect(entry.pricedRequestCount == 1)
    }

    @Test
    func `requests on different local days produce separate entries`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Int64(self.now.timeIntervalSince1970)
        try Self.insertNode(
            databaseURL: env.databaseURL,
            requestID: "req-1",
            generationModel: "swe-2-high",
            createdAt: now - 60,
            input: 100,
            output: 10)
        try Self.insertNode(
            databaseURL: env.databaseURL,
            requestID: "req-2",
            generationModel: "swe-2-high",
            createdAt: now - 26 * 3600,
            input: 200,
            output: 20)

        let report = try self.report(
            databaseURL: env.databaseURL,
            since: self.now.addingTimeInterval(-48 * 3600))
        #expect(report?.data.count == 2)
        #expect(report?.data.map(\.date).sorted() == report?.data.map(\.date))
    }

    @Test
    func `null cache fields count as zero tokens`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertNode(
            databaseURL: env.databaseURL,
            requestID: "req-1",
            generationModel: "swe-2-high",
            createdAt: Int64(self.now.timeIntervalSince1970) - 60,
            input: 100,
            output: 50,
            cacheRead: nil,
            cacheCreation: nil)

        let report = try self.report(databaseURL: env.databaseURL)
        let entry = try #require(report?.data.only)
        #expect(entry.cacheReadTokens == 0)
        #expect(entry.cacheCreationTokens == 0)
        #expect(entry.totalTokens == 150)
    }

    @Test
    func `missing database returns nil report`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let report = try self.report(databaseURL: env.databaseURL)
        #expect(report == nil)
    }

    @Test
    func `cost fetcher reads the devin cli session database`() async throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertNode(
            databaseURL: env.databaseURL,
            requestID: "req-1",
            generationModel: "swe-2-high",
            createdAt: Int64(self.now.timeIntervalSince1970) - 60,
            input: 500,
            output: 50)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .devin,
            environment: ["HOME": env.root.path],
            now: self.now,
            allowPricingRefresh: false)
        #expect(snapshot.daily.count == 1)
        #expect(snapshot.sessionTokens == 550)
        #expect(snapshot.last30DaysCostUSD == 0)
        #expect(snapshot.costProvenance == .listPriceEstimate)
        #expect(DevinProviderDescriptor.descriptor.cli.supportsCostCommand)
    }

    @Test
    func `cost fetcher reports empty history when the database is missing`() async throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .devin,
            environment: ["HOME": env.root.path],
            now: self.now,
            allowPricingRefresh: false)
        #expect(snapshot.daily.isEmpty)
    }

    @Test(arguments: [
        ("claude-sonnet-5-5-xhigh", DevinPricingRoute.claude("claude-sonnet-5-5")),
        ("claude-sonnet-5-5", DevinPricingRoute.claude("claude-sonnet-5-5")),
        ("claude-opus-5-5", DevinPricingRoute.claude("claude-opus-5-5")),
        ("claude-haiku-4-5-max", DevinPricingRoute.claude("claude-haiku-4-5")),
        ("swe-2-high", .free),
        ("swe-2-max", .free),
        ("compactor", .free),
        ("gpt-x", .unknown),
        ("fictional-model-x", .unknown),
        ("", .unknown),
    ])
    func `pricing routes classify generation models`(model: String, expected: DevinPricingRoute) {
        #expect(DevinLocalCostReader.pricingRoute(for: model) == expected)
    }

    // MARK: - Fixtures

    private var now: Date {
        Date(timeIntervalSince1970: 1_792_886_400 + 12 * 3600)
    }

    private func report(
        databaseURL: URL,
        since: Date? = nil,
        catalog: ModelsDevCatalog? = nil,
        customPricing: CostUsageCustomPricing = .empty) throws -> CostUsageDailyReport?
    {
        let until = self.now
        let reader = DevinLocalCostReader(databaseURL: databaseURL)
        return try reader.makeDailyReport(
            since: since ?? until.addingTimeInterval(-24 * 3600),
            until: until,
            calendar: Self.utcCalendar,
            catalog: catalog ?? Self.catalog(),
            modelsDevCacheRoot: nil,
            customPricing: customPricing)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private static func catalog() -> ModelsDevCatalog? {
        try? JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-opus-5-5": {
                "id": "claude-opus-5-5",
                "cost": { "input": 4, "output": 20, "cache_read": 0.2, "cache_write": 5 }
              },
              "claude-sonnet-5-5": {
                "id": "claude-sonnet-5-5",
                "cost": { "input": 2, "output": 10, "cache_read": 0.2, "cache_write": 2.5 }
              }
            }
          }
        }
        """.utf8))
    }

    private struct Environment {
        let root: URL
        let databaseURL: URL
    }

    private static func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devin-cost-tests-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root
            .appendingPathComponent(".local/share/devin/cli", isDirectory: true)
            .appendingPathComponent("sessions.db", isDirectory: false)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        return Environment(root: root, databaseURL: databaseURL)
    }

    private static func createDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try Self.exec(db: db, sql: """
        CREATE TABLE message_nodes (
          row_id INTEGER PRIMARY KEY,
          session_id TEXT,
          node_id INTEGER,
          parent_node_id INTEGER,
          chat_message TEXT,
          created_at INTEGER,
          metadata TEXT
        );
        """)
    }

    // swiftlint:disable:next function_parameter_count
    private static func insertNode(
        databaseURL: URL,
        requestID: String?,
        generationModel: String?,
        createdAt: Int64,
        input: Int,
        output: Int,
        cacheRead: Int? = 0,
        cacheCreation: Int? = 0) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        let metrics: [String: Any] = [
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_tokens": cacheRead ?? NSNull(),
            "cache_creation_tokens": cacheCreation ?? NSNull(),
            "context_input_tokens": input + (cacheRead ?? 0),
        ]
        var metadata: [String: Any] = ["metrics": metrics]
        if let requestID { metadata["request_id"] = requestID }
        if let generationModel { metadata["generation_model"] = generationModel }
        let chatMessage: [String: Any] = ["metadata": metadata]
        let data = try JSONSerialization.data(withJSONObject: chatMessage)
        let json = String(data: data, encoding: .utf8) ?? "{}"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO message_nodes (session_id, node_id, parent_node_id, chat_message, created_at, metadata)
            VALUES (?, 0, 0, ?, ?, NULL)
            """,
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "session-1", -1, transient)
        sqlite3_bind_text(stmt, 2, json, -1, transient)
        sqlite3_bind_int64(stmt, 3, createdAt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            sqlite3_free(message)
            throw SQLiteTestError.exec
        }
    }

    private enum SQLiteTestError: Error {
        case open
        case prepare
        case step
        case exec
    }
}

extension Collection {
    fileprivate var only: Element? {
        self.count == 1 ? self.first : nil
    }
}

#endif
