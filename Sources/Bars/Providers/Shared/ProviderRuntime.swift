import BarsCore
import Foundation

struct ProviderRuntimeContext {
    let provider: UsageProvider
    let settings: SettingsStore
    let store: UsageStore
}

@MainActor
protocol ProviderRuntime: AnyObject {
    var id: UsageProvider { get }

    func start(context: ProviderRuntimeContext)
    func stop(context: ProviderRuntimeContext)
    func settingsDidChange(context: ProviderRuntimeContext)
}

extension ProviderRuntime {
    func start(context _: ProviderRuntimeContext) {}
    func stop(context _: ProviderRuntimeContext) {}
    func settingsDidChange(context _: ProviderRuntimeContext) {}
}
