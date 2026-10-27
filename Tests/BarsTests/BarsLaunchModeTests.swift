import Testing
@testable import Bars

struct BarsLaunchModeTests {
    @Test
    func `normal launch starts the application`() {
        #expect(BarsLaunchMode.resolve(arguments: ["/Applications/bars"]) == .application)
    }

    @Test
    func `hook event launch skips application initialization`() {
        #expect(BarsLaunchMode.resolve(
            arguments: ["/Applications/bars", "--hook-event"]) == .hookEvent)
    }

    @Test
    func `hook event is recognized among other arguments`() {
        #expect(BarsLaunchMode.resolve(
            arguments: ["/Applications/bars", "--verbose", "--hook-event"]) == .hookEvent)
    }

    @Test
    func `similar argument still starts the application`() {
        #expect(BarsLaunchMode.resolve(
            arguments: ["/Applications/bars", "--hook-events"]) == .application)
    }
}
