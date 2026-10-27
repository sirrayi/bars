import Foundation

enum ProviderSessionStoreFile {
    static let isolationEnvironmentKey = "BARS_TEST_SESSION_FILE_ISOLATION"

    private static let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("bars-session-tests-\(UUID().uuidString)", isDirectory: true)

    static func url(
        for filename: String,
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        testDirectory: URL? = nil,
        applicationSupportDirectory: () -> URL = {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }) -> URL
    {
        let directory: URL
            // Keychain opt-ins never authorize session-file access. Resolve isolation before consulting user paths.
            = if environment[self.isolationEnvironmentKey] == "1"
            || KeychainTestSafety.isRunningUnderTests(processName: processName, environment: environment)
        {
            testDirectory ?? self.testDirectory
        } else {
            applicationSupportDirectory().appendingPathComponent("bars", isDirectory: true)
        }
        return directory.appendingPathComponent(filename)
    }
}
