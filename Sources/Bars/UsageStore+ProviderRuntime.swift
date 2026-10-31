import BarsCore

extension UsageStore {
    func updateProviderRuntimes() {
        for (instanceID, runtime) in self.providerRuntimes {
            guard let provider = instanceID.firstPartyProvider else { continue }
            let context = ProviderRuntimeContext(provider: provider, settings: self.settings, store: self)
            if self.isEnabled(provider) {
                runtime.start(context: context)
            } else {
                runtime.stop(context: context)
            }
            runtime.settingsDidChange(context: context)
        }
    }
}
