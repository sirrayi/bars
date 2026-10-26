import Foundation
import Testing
@testable import CodexBarCore

@Suite(CodexCredentialFixtures())
struct ManagedCodexFreshCredentialResolverTests {
    @Test
    func `resolver never falls back to credential-hydrating account loading`() throws {
        let fixture = try Self.fixture()
        let store = FallbackProbeStore(accounts: [fixture.account])
        let resolver = ManagedCodexAccountCredentialResolver(
            store: store,
            managedHomeRoot: fixture.root,
            now: { fixture.now },
            snapshotReader: { _ in Self.snapshot(fixture) })

        guard case .ready = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0) else {
            Issue.record("Expected metadata-only account observation to resolve")
            return
        }
        #expect(store.hydratingReadCount == 0)
        #expect(store.metadataWasLoaded)
    }

    @Test
    func `native snapshot diagnostics and reflection redact the bearer`() {
        let canary = "CA1_SECRET_CANARY_snapshot_diagnostics"
        let snapshot = NativeCodexAccessSnapshot(
            accessToken: canary,
            expiresAt: Date(timeIntervalSince1970: 1_700_003_600),
            nativeDefaultAccountID: "acct-synthetic",
            nativeOwnerEmail: canary)

        #expect(!snapshot.description.contains(canary))
        #expect(!snapshot.debugDescription.contains(canary))
        #expect(!String(describing: snapshot).contains(canary))
        #expect(!String(reflecting: snapshot).contains(canary))
        #expect(Array(snapshot.customMirror.children).isEmpty)
    }

    @Test
    func `resolver returns a redacted access-only credential for a stable fresh managed account`() throws {
        let fixture = try Self.fixture()
        let canary = "CA1_SECRET_CANARY_fresh_access"
        let resolver = Self.resolver(fixture: fixture) { _ in
            NativeCodexAccessSnapshot(
                accessToken: canary,
                expiresAt: fixture.now.addingTimeInterval(3600),
                nativeDefaultAccountID: fixture.account.effectiveWorkspaceAccountID,
                nativeOwnerEmail: fixture.account.email)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 120)

        guard case let .ready(credential) = resolution else {
            Issue.record("Expected a fresh stable account to resolve")
            return
        }
        #expect(credential.expiresAt == fixture.now.addingTimeInterval(3600))
        if !credential.withAccessToken({ $0 == canary }) {
            Issue.record("Expected access projection to preserve the synthetic value")
        }
        #expect(!String(describing: credential).contains(canary))
        #expect(!String(reflecting: credential).contains(canary))
    }

    @Test
    func `resolver rejects an unknown managed account before reading a credential`() throws {
        let fixture = try Self.fixture()
        let resolver = Self.resolver(fixture: fixture) { _ in
            Issue.record("Unknown accounts must not read credentials")
            return Self.snapshot(fixture)
        }

        let resolution = resolver.resolve(accountID: UUID(), minimumValidity: 0)

        guard case .accountNotFound = resolution else {
            Issue.record("Expected unknown UUID to stay distinguishable")
            return
        }
    }

    @Test
    func `resolver rejects an account home outside its managed root`() throws {
        let fixture = try Self.fixture(homePath: CodexCredentialFixtures.root.path)
        let resolver = Self.resolver(fixture: fixture) { _ in
            Issue.record("Untrusted homes must not read credentials")
            return Self.snapshot(fixture)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case let .unsupported(reason) = resolution else {
            Issue.record("Expected outside root to be unsupported")
            return
        }
        #expect(reason == .untrustedManagedHome)
    }

    @Test
    func `resolver rejects a managed home symlink`() throws {
        let root = CodexCredentialFixtures.root.appendingPathComponent("managed-homes", isDirectory: true)
        let realHome = root.appendingPathComponent("real-home", isDirectory: true)
        let linkedHome = root.appendingPathComponent("linked-home", isDirectory: true)
        try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: realHome.appendingPathComponent("auth.json"))
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)
        let fixture = try Self.fixture(root: root, homePath: linkedHome.path)
        let resolver = Self.resolver(fixture: fixture) { _ in
            Issue.record("Symlink homes must not read credentials")
            return Self.snapshot(fixture)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case let .unsupported(reason) = resolution else {
            Issue.record("Expected symlink home to be unsupported")
            return
        }
        #expect(reason == .untrustedManagedHome)
    }

    @Test
    func `resolver requires compatible native default workspace`() throws {
        let fixture = try Self.fixture()
        let resolver = Self.resolver(fixture: fixture) { _ in
            NativeCodexAccessSnapshot(
                accessToken: "synthetic-access",
                expiresAt: fixture.now.addingTimeInterval(3600),
                nativeDefaultAccountID: "acct-other",
                nativeOwnerEmail: fixture.account.email)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case let .unsupported(reason) = resolution else {
            Issue.record("Expected mismatched workspace to be unsupported")
            return
        }
        #expect(reason == .workspaceScope)
    }

    @Test
    func `resolver binds an account without explicit workspace selection to the native default`() throws {
        let fixture = try Self.fixture(workspaceAccountID: nil)
        let resolver = Self.resolver(fixture: fixture) { _ in
            NativeCodexAccessSnapshot(
                accessToken: "synthetic-access",
                expiresAt: fixture.now.addingTimeInterval(3600),
                nativeDefaultAccountID: "acct-native-default",
                nativeOwnerEmail: fixture.account.email)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case .ready = resolution else {
            Issue.record("An unscoped account should bind to the native default workspace")
            return
        }
    }

    @Test
    func `resolver refuses to bind when native workspace evidence is absent`() throws {
        let fixture = try Self.fixture(workspaceAccountID: nil)
        let resolver = Self.resolver(fixture: fixture) { _ in
            NativeCodexAccessSnapshot(
                accessToken: "synthetic-access",
                expiresAt: fixture.now.addingTimeInterval(3600),
                nativeDefaultAccountID: nil,
                nativeOwnerEmail: fixture.account.email)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case let .unsupported(reason) = resolution else {
            Issue.record("Missing native workspace evidence must not resolve")
            return
        }
        #expect(reason == .bindingEvidenceInsufficient)
    }

    private static func resolver(
        fixture: Fixture,
        snapshotReader: @escaping @Sendable (URL) throws -> NativeCodexAccessSnapshot)
        -> ManagedCodexAccountCredentialResolver
    {
        ManagedCodexAccountCredentialResolver(
            store: fixture.store,
            managedHomeRoot: fixture.root,
            policy: .init(authorityMinimumValidity: 60, clockSkew: 30),
            now: { fixture.now },
            snapshotReader: snapshotReader)
    }

    private static func snapshot(_ fixture: Fixture) -> NativeCodexAccessSnapshot {
        NativeCodexAccessSnapshot(
            accessToken: "synthetic-access",
            expiresAt: fixture.now.addingTimeInterval(3600),
            nativeDefaultAccountID: fixture.account.effectiveWorkspaceAccountID,
            nativeOwnerEmail: fixture.account.email)
    }

    private static func fixture(
        root: URL? = nil,
        homePath: String? = nil,
        workspaceAccountID: String? = "acct-default") throws -> Fixture
    {
        let root = root ?? CodexCredentialFixtures.root
            .appendingPathComponent("managed-homes", isDirectory: true)
        let home = homePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appendingPathComponent("managed-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let authURL = home.appendingPathComponent("auth.json")
        if !FileManager.default.fileExists(atPath: authURL.path) {
            try Data("{}".utf8).write(to: authURL)
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = ManagedCodexAccount(
            id: UUID(),
            email: "resolver@example.com",
            workspaceAccountID: workspaceAccountID,
            managedHomePath: home.path,
            createdAt: now.timeIntervalSince1970,
            updatedAt: now.timeIntervalSince1970,
            lastAuthenticatedAt: now.timeIntervalSince1970)
        return Fixture(
            root: root,
            now: now,
            account: account,
            authURL: authURL,
            store: InMemoryStore(accounts: [account]))
    }

    private final class FallbackProbeStore: ManagedCodexAccountStoring, ManagedCodexAccountMetadataLoading,
        @unchecked Sendable
    {
        let accounts: [ManagedCodexAccount]
        private(set) var hydratingReadCount = 0
        private(set) var metadataWasLoaded = false

        init(accounts: [ManagedCodexAccount]) {
            self.accounts = accounts
        }

        func loadAccounts() throws -> ManagedCodexAccountSet {
            self.hydratingReadCount += 1
            return ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: self.accounts)
        }

        func loadAccountMetadata() throws -> ManagedCodexAccountSet {
            self.metadataWasLoaded = true
            return ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: self.accounts)
        }

        func storeAccounts(_: ManagedCodexAccountSet) throws {
            Issue.record("A fresh resolver must not persist account metadata")
        }

        func ensureFileExists() throws -> URL {
            Issue.record("A fresh resolver must not create account metadata")
            return URL(fileURLWithPath: "/invalid")
        }
    }

    private struct Fixture: @unchecked Sendable {
        let root: URL
        let now: Date
        let account: ManagedCodexAccount
        let authURL: URL
        let store: InMemoryStore
    }

    private final class InMemoryStore: ManagedCodexAccountMetadataLoading, @unchecked Sendable {
        let accounts: [ManagedCodexAccount]

        init(accounts: [ManagedCodexAccount]) {
            self.accounts = accounts
        }

        func loadAccountMetadata() throws -> ManagedCodexAccountSet {
            ManagedCodexAccountSet(version: FileManagedCodexAccountStore.currentVersion, accounts: self.accounts)
        }
    }
}
