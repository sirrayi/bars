import CodexBarCore

extension StatusItemController {
    func menuLocalizationSignature() -> String {
        [
            codexBarLocalizationSignature(),
            self.settings.hidePersonalInfo ? "hide-personal-info" : "show-personal-info",
            L("Overview"),
            L("Cost"),
        ].joined(separator: "|")
    }

    func rememberMergedSwitcherState(_ providers: [UsageProvider], _ selection: ProviderSwitcherSelection?) {
        self.rememberMergedSwitcherState(
            providers,
            selection,
            self.includesOverviewTab(enabledProviders: providers))
    }

    func rememberMergedSwitcherState(
        _ providers: [UsageProvider],
        _ selection: ProviderSwitcherSelection?,
        _ includesOverview: Bool)
    {
        self.lastSwitcherProviders = self.switcherProviderIDs(enabledFirstPartyProviders: providers)
        self.lastSwitcherUsageBarsShowUsed = self.settings.usageBarsShowUsed
        self.lastMergedSwitcherSelection = selection
        self.lastMergedMenuContentSelection = selection
        self.lastSwitcherIncludesOverview = includesOverview
        self.lastMenuLocalizationSignature = self.menuLocalizationSignature()
    }
}
