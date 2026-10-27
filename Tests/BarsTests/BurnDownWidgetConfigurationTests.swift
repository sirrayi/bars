import Testing
@testable import BarsWidget

struct BurnDownWidgetConfigurationTests {
    @Test
    func `burn down widget background is removable by the system`() {
        #expect(BurnDownWidgetBackgroundConfiguration.isRemovable)
    }
}
