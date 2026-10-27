import BarsCore

extension UsageStore {
    func logStartupState() {
        let modeSnapshot: [String: String] = [
            "claudeUsageSource": self.settings.claudeUsageDataSource.rawValue,
            "claudeCookieSource": self.settings.claudeCookieSource.rawValue,
            "opencodeCookieSource": self.settings.opencodeCookieSource.rawValue,
            "opencodegoCookieSource": self.settings.opencodegoCookieSource.rawValue,
            "backgroundWorkLowPowerMode": self.settings.backgroundWorkLowPowerModeEnabled ? "1" : "0",
            "claudeWebExtras": self.settings.claudeWebExtrasEnabled ? "1" : "0",
        ]
        ProviderLogging.logStartupState(
            logger: self.providerLogger,
            providers: Array(self.providerMetadata.keys),
            isEnabled: { provider in
                self.settings.isProviderEnabled(
                    provider: provider,
                    metadata: self.providerMetadata[provider]!)
            },
            modeSnapshot: modeSnapshot)
    }
}
