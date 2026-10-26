import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct FrontmostProviderMonitorTests {
    @Test
    func `monitor only runs while frontmost source can affect the collapsed merged icon`() {
        #expect(FrontmostProviderMonitoringPolicy.shouldRun(
            source: .frontmostApp, mergeIcons: true, isStacked: false))
        for source in [UnifiedIconSource.currentSelection, .highestUsage] {
            #expect(!FrontmostProviderMonitoringPolicy.shouldRun(
                source: source, mergeIcons: true, isStacked: false))
        }
        #expect(!FrontmostProviderMonitoringPolicy.shouldRun(
            source: .frontmostApp, mergeIcons: false, isStacked: false))
        #expect(!FrontmostProviderMonitoringPolicy.shouldRun(
            source: .frontmostApp, mergeIcons: true, isStacked: true))
    }
}

@MainActor
private final class FakeFrontmostApplicationEventSource: FrontmostApplicationEventSource {
    var frontmostBundleIdentifier: String?
    var startCount = 0
    var stopCount = 0
    private var onChange: (@MainActor () -> Void)?

    init(bundleIdentifier: String?) {
        self.frontmostBundleIdentifier = bundleIdentifier
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.startCount += 1
        self.onChange = onChange
    }

    func stop() {
        self.stopCount += 1
        self.onChange = nil
    }

    func activate(_ bundleIdentifier: String?) {
        self.frontmostBundleIdentifier = bundleIdentifier
        self.onChange?()
    }

    func terminateFrontmost() {
        self.activate(nil)
    }
}
