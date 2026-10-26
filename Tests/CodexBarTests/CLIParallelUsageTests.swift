import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

enum CLIParallelUsageTests {
    private actor SlowProviders {
        private var active = 0
        private(set) var peak = 0
    }
}
