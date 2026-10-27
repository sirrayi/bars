import BarsCore
import Foundation
import Testing
@testable import BarsCLI

enum CLIParallelUsageTests {
    private actor SlowProviders {
        private var active = 0
        private(set) var peak = 0
    }
}
