import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ProviderSessionStoreFileTests {
    @Test(arguments: ["swiftpm-testing-helper", "CodexBarPackageTests", "CodexBarPackageTests.xctest"])
    func `process names isolate session files even when real Keychain is allowed`(processName: String) {
        let root = URL(fileURLWithPath: "/synthetic/session-tests")
        let url = ProviderSessionStoreFile.url(
            for: "fixture.json",
            processName: processName,
            environment: ["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "1"],
            testDirectory: root,
            applicationSupportDirectory: {
                Issue.record("Test path selection consulted user Application Support")
                return URL(fileURLWithPath: "/synthetic/user")
            })
        #expect(url == root.appendingPathComponent("fixture.json"))
    }

    @Test(arguments: [
        "XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier",
        "TESTING_LIBRARY_VERSION", "SWIFT_TESTING", "SWIFT_TESTING_ENABLED",
        "CODEXBAR_TEST_SESSION_FILE_ISOLATION",
    ])
    func `runtime markers and child process signals isolate session files`(marker: String) {
        let root = URL(fileURLWithPath: "/synthetic/session-tests")
        let url = ProviderSessionStoreFile.url(
            for: "fixture.json",
            processName: "CodexBarCLI",
            environment: [marker: "1"],
            testDirectory: root,
            applicationSupportDirectory: {
                Issue.record("A test child consulted user Application Support")
                return URL(fileURLWithPath: "/synthetic/user")
            })
        #expect(url == root.appendingPathComponent("fixture.json"))
    }

    @Test
    func `ordinary execution retains the production relative path using a fake root`() {
        let root = URL(fileURLWithPath: "/synthetic/Application Support", isDirectory: true)
        for filename in ["cursor-session.json", "augment-session.json", "factory-session.json", "notion-session.json"] {
            let url = ProviderSessionStoreFile.url(
                for: filename,
                processName: "CodexBar",
                environment: [:],
                applicationSupportDirectory: { root })
            #expect(url == root.appendingPathComponent("CodexBar").appendingPathComponent(filename))
        }
    }

    private static func cookie(value: String, expires: Date = Date(timeIntervalSinceNow: 3600)) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: "fixture", .value: value, .domain: "session.test", .path: "/", .expires: expires, .secure: true,
        ]))
    }
}
