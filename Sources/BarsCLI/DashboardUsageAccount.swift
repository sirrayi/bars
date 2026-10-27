import BarsCore
import Foundation

/// Account presentation metadata travels beside usage, including failed fetches.
/// Never derive public IDs from cacheAccountKey, email, or authFingerprint.
struct DashboardUsageAccount: Sendable {
    let id: String
    let label: String
    let active: Bool

    static func token(_ account: ProviderTokenAccount, active: Bool) -> Self {
        Self(id: "token:\(account.id.uuidString.lowercased())", label: account.label, active: active)
    }
}

extension UsageCommandOutput {
    mutating func attachDashboardAccount(_ account: DashboardUsageAccount?, inventoryIncomplete: Bool = false) {
        for index in self.payload.indices {
            if let account { self.payload[index].dashboardAccount = account }
            self.payload[index].dashboardAccountsIncomplete = self.payload[index].dashboardAccountsIncomplete
                || inventoryIncomplete
        }
    }
}
