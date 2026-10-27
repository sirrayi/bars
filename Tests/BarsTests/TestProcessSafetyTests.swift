import Testing
@testable import BarsCore

struct TestProcessSafetyTests {
    @Test
    func `current process is recognized without callers supplying runner signals`() {
        #expect(TestProcessSafety.isRunning)
    }

    @Test(arguments: [["/tmp/Suite.xctest"], ["swift-testing"], ["/tmp/XCTestRunner"]])
    func `recognizes runner executable arguments`(arguments: [String]) {
        #expect(TestProcessSafety.isRunningUnderTests(
            processName: "runner",
            environment: [:],
            arguments: arguments))
    }

    @Test(arguments: [
        ["/usr/local/bin/bars", "--account", "swift-testing"],
        ["/usr/local/bin/bars", "--account", "xctest"],
        ["/usr/local/bin/bars", "--account", "Example.xctest"],
        ["/tmp/swift-testing/bars", "usage"],
        ["/tmp/Example.xctest/bars", "usage"],
        ["/tmp/XCTestRunnerTools/bars", "usage"],
    ])
    func `ordinary argument values and installation paths retain production behavior`(arguments: [String]) {
        #expect(!TestProcessSafety.isRunningUnderTests(
            processName: "bars",
            environment: [:],
            arguments: arguments))
    }

    @Test(arguments: [
        ("swiftpm-testing-helper", [:]),
        ("BarsPackageTests", [:]),
        ("BarsPackageTests.xctest", [:]),
        ("bars", ["XCTestConfigurationFilePath": "fixture"]),
        ("bars", ["XCTestBundlePath": "fixture"]),
        ("bars", ["XCTestSessionIdentifier": "fixture"]),
        ("bars", ["TESTING_LIBRARY_VERSION": "fixture"]),
        ("bars", ["SWIFT_TESTING": "fixture"]),
        ("bars", ["SWIFT_TESTING_ENABLED": "fixture"]),
    ] as [(String, [String: String])])
    func `recognizes every supported runner signal`(
        processName: String,
        environment: [String: String])
    {
        #expect(TestProcessSafety.isRunningUnderTests(
            processName: processName,
            environment: environment))
    }

    @Test
    func `recognizes the loaded XCTest fallback without class lookup side effects`() {
        #expect(TestProcessSafety.isRunningUnderTests(
            processName: "bars",
            environment: [:],
            hasLoadedXCTestCase: true))
    }

    @Test
    func `does not classify an ordinary app process as a test runner`() {
        #expect(!TestProcessSafety.isRunningUnderTests(
            processName: "bars",
            environment: [:]))
    }
}
