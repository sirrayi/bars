import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared, lock-guarded ISO8601 formatters for status feeds; allocating one per decoded date is wasteful.
private final class StatusISO8601FormatterBox: @unchecked Sendable {
    let lock = NSLock()
    let withFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    let plain: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()
}

private enum StatusFeedDateParser {
    static let box = StatusISO8601FormatterBox()

    static func parse(_ text: String) -> Date? {
        self.box.lock.lock()
        defer { self.box.lock.unlock() }
        return self.box.withFractional.date(from: text) ?? self.box.plain.date(from: text)
    }

    static func decodingStrategy() -> JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = StatusFeedDateParser.parse(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
            }
            return date
        }
    }
}

package enum ProviderStatusFetcher {
    /// Status feeds decode off the main actor; these helpers touch no store state.
    @concurrent
    package static func fetchStatus(
        from baseURL: URL,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared)
        async throws -> ProviderStatus
    {
        let apiURL = baseURL.appendingPathComponent("api/v2/status.json")
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 10

        let (data, _) = try await transport.data(for: request)

        return try Self.parseStatuspageStatus(data: data)
    }

    /// Resolves the provider's status and component list from an Atlassian statuspage.io feed.
    /// `components.json` is used for the flat list because `summary.json` omits unlisted components.
    @concurrent
    package static func fetchStatusSummary(
        from baseURL: URL,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared)
        async throws -> (status: ProviderStatus, components: [ProviderStatusComponent]?)
    {
        var summaryRequest = URLRequest(url: baseURL.appendingPathComponent("api/v2/summary.json"))
        summaryRequest.timeoutInterval = 10
        var componentsRequest = URLRequest(url: baseURL.appendingPathComponent("api/v2/components.json"))
        componentsRequest.timeoutInterval = 10

        let (summaryData, _) = try await transport.data(for: summaryRequest)
        let status = try Self.parseStatuspageStatus(data: summaryData)
        let components: [ProviderStatusComponent]? = if let (componentsData, _) = try? await transport
            .data(for: componentsRequest)
        {
            try? Self.parseStatuspageComponents(data: componentsData)
        } else {
            nil
        }
        return (status, components)
    }

    package static func parseStatuspageStatus(data: Data) throws -> ProviderStatus {
        struct Response: Decodable {
            struct Status: Decodable {
                let indicator: String
                let description: String?
            }

            struct Page: Decodable {
                let updatedAt: Date?

                private enum CodingKeys: String, CodingKey {
                    case updatedAt = "updated_at"
                }
            }

            let page: Page?
            let status: Status
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = StatusFeedDateParser.decodingStrategy()
        let response = try decoder.decode(Response.self, from: data)
        let indicator = ProviderStatusIndicator(rawValue: response.status.indicator) ?? .unknown
        return ProviderStatus(
            indicator: indicator,
            description: response.status.description,
            updatedAt: response.page?.updatedAt)
    }

    package static func parseStatuspageComponents(data: Data) throws -> [ProviderStatusComponent] {
        struct Response: Decodable {
            struct Component: Decodable {
                let id: String
                let name: String
                let status: String
                let group: Bool?
                let groupID: String?
                let position: Int?

                private enum CodingKeys: String, CodingKey {
                    case id, name, status, group, position
                    case groupID = "group_id"
                }
            }

            let components: [Component]?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        let raw = (response.components ?? [])
            .filter { Self.normalizedStatusComponentName($0.name) != nil }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }

        func makeRow(
            _ component: Response.Component,
            children: [ProviderStatusComponent]) -> ProviderStatusComponent
        {
            ProviderStatusComponent(
                id: component.id,
                name: Self.normalizedStatusComponentName(component.name) ?? component.name,
                indicator: ProviderStatusComponent.indicator(forStatuspageStatus: component.status),
                status: component.status,
                children: children)
        }

        // Children keyed by their parent group id, preserving position order.
        var childrenByGroup: [String: [ProviderStatusComponent]] = [:]
        for component in raw where component.group != true {
            guard let groupID = component.groupID else { continue }
            childrenByGroup[groupID, default: []].append(makeRow(component, children: []))
        }

        // Top-level rows: groups (with their children) and ungrouped leaf components, in order.
        return raw.compactMap { component in
            if component.group == true {
                return makeRow(component, children: childrenByGroup[component.id] ?? [])
            }
            // Skip leaves that belong to a group; they are rendered inside the group's dropdown.
            if component.groupID != nil { return nil }
            return makeRow(component, children: [])
        }
    }

    private nonisolated static func normalizedStatusComponentName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}
