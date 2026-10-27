import BarsCore
import Foundation

struct SpendSourcePublication: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case loading
        case available
        case confirmedEmpty
        case unavailable
        case staleLastKnown
    }

    let id: String
    let provider: UsageProvider?
    let displayName: String
    let state: State
}

struct SpendDashboardPublication: Sendable {
    let revision: UInt64
    let generation: UInt64
    let configuration: SpendDashboardConfiguration?
    let loadedAt: Date
    let isRefreshing: Bool
    let inputs: [SpendDashboardModel.ProviderInput]
    let sources: [SpendSourcePublication]

    static let empty = SpendDashboardPublication(
        revision: 0,
        generation: 0,
        configuration: nil,
        loadedAt: .distantPast,
        isRefreshing: false,
        inputs: [],
        sources: [])

    func model(
        requestedDays: Int,
        reportingPeriod: CostReportingPeriod? = nil,
        now: Date,
        calendar: Calendar,
        preferredCurrencyCode: String,
        hiddenSourceIDs: Set<String> = [],
        selectedDay: Date? = nil,
        providerScope: Set<UsageProvider>? = nil) -> SpendDashboardModel
    {
        let staleSourceIDs = Set(self.sources.compactMap { source in
            source.state == .staleLastKnown ? source.id : nil
        })
        let inputs = self.inputs.filter { input in
            (providerScope?.contains(input.provider) ?? true) && !staleSourceIDs.contains(input.id)
        }
        return SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: requestedDays,
            reportingPeriod: reportingPeriod,
            now: now,
            calendar: calendar,
            preferredCurrencyCode: preferredCurrencyCode,
            hiddenSourceIDs: hiddenSourceIDs,
            selectedDay: selectedDay)
    }

    func subscriptionCount(
        providerScope: Set<UsageProvider>,
        hiddenSourceIDs: Set<String> = []) -> Int
    {
        providerScope.reduce(into: 0) { count, provider in
            let coverageSources = self.coverageSources(for: provider, hiddenSourceIDs: hiddenSourceIDs)
            if self.subscriptionRosterSources(for: provider).isEmpty, coverageSources.isEmpty {
                count += hiddenSourceIDs.contains(provider.rawValue) ? 0 : 1
            } else {
                count += coverageSources.count
            }
        }
    }

    func knownCostSubscriptionCount(
        model: SpendDashboardModel,
        providerScope: Set<UsageProvider>,
        hiddenSourceIDs: Set<String> = []) -> Int
    {
        let knownInputIDs = Set(model.groups.flatMap(\.providers).compactMap { row in
            row.totalCost == nil ? nil : row.id
        })
        return self.knownSubscriptionCount(
            knownInputIDs: knownInputIDs,
            providerScope: providerScope,
            hiddenSourceIDs: hiddenSourceIDs)
    }

    func knownTokenSubscriptionCount(
        model: SpendDashboardModel,
        providerScope: Set<UsageProvider>,
        hiddenSourceIDs: Set<String> = []) -> Int
    {
        let knownInputIDs = Set(model.groups.flatMap(\.providers).compactMap { row in
            row.totalTokens == nil ? nil : row.id
        })
        return self.knownSubscriptionCount(
            knownInputIDs: knownInputIDs,
            providerScope: providerScope,
            hiddenSourceIDs: hiddenSourceIDs)
    }

    private func knownSubscriptionCount(
        knownInputIDs: Set<String>,
        providerScope: Set<UsageProvider>,
        hiddenSourceIDs: Set<String>) -> Int
    {
        providerScope.reduce(into: 0) { count, provider in
            count += self.coverageSources(for: provider, hiddenSourceIDs: hiddenSourceIDs)
                .count { source in
                    source.state == .confirmedEmpty ||
                        (source.state == .available && knownInputIDs.contains(source.id))
                }
        }
    }

    private func subscriptionRosterSources(for provider: UsageProvider) -> [SpendSourcePublication] {
        self.sources.filter { $0.provider == provider }
    }

    private func coverageSources(
        for provider: UsageProvider,
        hiddenSourceIDs: Set<String>) -> [SpendSourcePublication]
    {
        self.subscriptionRosterSources(for: provider).filter { !hiddenSourceIDs.contains($0.id) }
    }
}
