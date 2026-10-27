import Foundation
import Testing
@testable import BarsCore

struct AppGroupSupportTests {
    @Test
    func `app group identifiers use resolved team-prefixed release and debug variants`() {
        #expect(
            AppGroupSupport.currentGroupID(teamID: "BARSADHOC1", bundleID: "com.sirrayi.bars")
                == "BARSADHOC1.com.sirrayi.bars")
        #expect(
            AppGroupSupport.currentGroupID(teamID: "ABCDE12345", bundleID: "com.sirrayi.bars.debug")
                == "ABCDE12345.com.sirrayi.bars.debug")
    }

    @Test
    func `resolved team id falls back to plist and then default`() {
        #expect(
            AppGroupSupport.resolvedTeamID(
                infoDictionaryOverride: [AppGroupSupport.teamIDInfoKey: "ABCDE12345"],
                bundleURLOverride: nil) == "ABCDE12345")
        #expect(
            AppGroupSupport.resolvedTeamID(
                infoDictionaryOverride: nil,
                bundleURLOverride: nil) == AppGroupSupport.defaultTeamID)
    }
}
