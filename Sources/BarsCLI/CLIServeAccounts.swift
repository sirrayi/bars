import BarsCore
import Foundation

struct CLIServeAccountsPayload: Encodable, Equatable {
    let schemaVersion: Int
    let accounts: [CLIServeAccountPayload]
}

struct CLIServeAccountPayload: Encodable, Equatable {
    let id: String
    let provider: String
    let source: String
    let label: String
    let active: Bool
    let identity: CLIServeAccountIdentityPayload?
}

struct CLIServeAccountIdentityPayload: Encodable, Equatable {
    let accountEmail: String?
}

enum CLIServeAccountDiscovery {
    private static let schemaVersion = 1
    private static let tokenAccountSource = "token-account"

    static func makePayload(
        config: BarsConfig,
        identityMode: DashboardIdentityMode) -> CLIServeAccountsPayload
    {
        var accounts = self.tokenAccounts(config: config, identityMode: identityMode)
        accounts.sort {
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.id < $1.id
        }
        return CLIServeAccountsPayload(schemaVersion: self.schemaVersion, accounts: accounts)
    }

    static func response(
        payload: CLIServeAccountsPayload,
        requestedID: String?) -> CLILocalHTTPResponse
    {
        if let requestedID {
            guard let account = payload.accounts.first(where: { $0.id == requestedID }) else {
                return BarsCLI.serveError(status: .notFound, message: "account not found")
            }
            return BarsCLI.serveJSON(account)
        }
        return BarsCLI.serveJSON(payload)
    }

    private static func tokenAccounts(
        config: BarsConfig,
        identityMode: DashboardIdentityMode) -> [CLIServeAccountPayload]
    {
        config.providers.flatMap { providerConfig -> [CLIServeAccountPayload] in
            guard let data = providerConfig.tokenAccounts else { return [] }
            let activeIndex = data.clampedActiveIndex()
            return data.accounts.enumerated().map { index, account in
                let identity = ProviderAccountIdentity(
                    source: self.tokenAccountSource,
                    opaqueID: account.id.uuidString.lowercased())
                return CLIServeAccountPayload(
                    id: "\(identity.source):\(providerConfig.id.rawValue):\(identity.opaqueID)",
                    provider: providerConfig.id.rawValue,
                    source: identity.source,
                    label: self.presentedLabel(account.label, accountID: identity.opaqueID, mode: identityMode),
                    active: index == activeIndex,
                    identity: nil)
            }
        }
    }

    private static func presentedLabel(
        _ raw: String,
        accountID: String,
        mode: DashboardIdentityMode) -> String
    {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return "Account \(accountID)" }
        // Mirror PersonalInfoRedactor's safe source-issued account placeholder convention.
        // This CLI target cannot depend on the app target where that helper lives.
        if mode == .redacted { return "Account \(accountID)" }
        guard mode != .none else { return label.contains("@") ? "Account \(accountID)" : label }
        return label
    }
}

extension BarsCLI {
    static func serveAccountsRoute(
        _ request: CLILocalHTTPRequest,
        id: String?,
        runtime: ServeRuntime) -> CLILocalHTTPResponse
    {
        guard !runtime.dataRoutesRequireAuth || runtime.dashboardAuth.authorize(request) else {
            return self.serveUnauthorizedResponse()
        }
        let config: BarsConfig
        do {
            config = try runtime.configStore.load() ?? BarsConfig.makeDefault()
        } catch {
            return self.addingNoStore(self.serveError(
                status: .internalServerError,
                message: "could not load accounts"))
        }
        let identityMode = self.resolveDashboardIdentityMode(
            configured: runtime.dashboardIdentityMode,
            hidesPersonalInfo: self.hidePersonalInfoFromDefaults())
        let payload = CLIServeAccountDiscovery.makePayload(
            config: config,
            identityMode: identityMode)
        return self.addingNoStore(CLIServeAccountDiscovery.response(
            payload: payload,
            requestedID: id))
    }
}
