import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct CreditEvent: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public let date: Date
    public let service: String
    public let creditsUsed: Double

    public init(id: UUID = UUID(), date: Date, service: String, creditsUsed: Double) {
        self.id = id
        self.date = date
        self.service = service
        self.creditsUsed = creditsUsed
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case service
        case creditsUsed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.date = try container.decode(Date.self, forKey: .date)
        self.service = try container.decode(String.self, forKey: .service)
        self.creditsUsed = try container.decode(Double.self, forKey: .creditsUsed)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.date, forKey: .date)
        try container.encode(self.service, forKey: .service)
        try container.encode(self.creditsUsed, forKey: .creditsUsed)
    }
}

public struct CreditsSnapshot: Equatable, Codable, Sendable {
    public let remaining: Double
    public let events: [CreditEvent]
    public let updatedAt: Date
    /// False when the provider omitted the balance, including cap-only responses and preservation placeholders.
    /// A successful read of `remaining == 0` stays true so reconciliation can clear a stale balance.
    public let balanceReadSucceeded: Bool
    /// Whether the provider explicitly reported a finite credit pool, even when it withheld the balance.
    /// This distinguishes a hidden workspace pool from a confirmed zero balance.
    public let creditsAvailable: Bool?

    /// Never expose an unread placeholder as a real zero.
    public var displayRemaining: Double? {
        self.balanceReadSucceeded ? self.remaining : nil
    }

    public init(
        remaining: Double,
        events: [CreditEvent],
        updatedAt: Date,
        balanceReadSucceeded: Bool = true,
        creditsAvailable: Bool? = nil)
    {
        self.remaining = remaining
        self.events = events
        self.updatedAt = updatedAt
        self.balanceReadSucceeded = balanceReadSucceeded
        self.creditsAvailable = creditsAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case remaining
        case events
        case updatedAt
        case balanceReadSucceeded
        case creditsAvailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.remaining = try container.decode(Double.self, forKey: .remaining)
        self.events = try container.decode([CreditEvent].self, forKey: .events)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.balanceReadSucceeded = try container.decodeIfPresent(Bool.self, forKey: .balanceReadSucceeded) ?? true
        self.creditsAvailable = try container.decodeIfPresent(Bool.self, forKey: .creditsAvailable)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.remaining, forKey: .remaining)
        try container.encode(self.events, forKey: .events)
        try container.encode(self.updatedAt, forKey: .updatedAt)
        try container.encode(self.balanceReadSucceeded, forKey: .balanceReadSucceeded)
        try container.encodeIfPresent(self.creditsAvailable, forKey: .creditsAvailable)
    }
}
