import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore
@testable import CodexBarWidget

// The exact-anchor catalog intentionally makes this test data file long.
// swiftlint:disable file_length

/// Provider architecture drift tripwire for honest mistakes by future contributors and AI agents.
///
/// This lexical scanner detects dotted provider cases, including qualified, labeled, and multiline statements, plus
/// lowercase raw provider-ID string literals in every single-statement position, including assignments, bare function
/// arguments, dictionary keys and values, array elements, and returns. It scans shipped Swift under `Sources/**` and
/// `WidgetExtension/**` and applies suppressions to exact provider tokens rather than whole statements.
///
/// Dotted provider cases that require real expression parsing, including implicit closure returns and closure-body
/// dataflow, are intentionally out of scope. String concatenation, reflection, and dynamic lookup are also out of
/// scope, as are `Tests/**` and non-Swift files. This test is a lexical drift tripwire for honest mistakes, not an
/// adversarially complete analyzer. Exact anchors follow line shifts; repeated text requires a 1-based occurrence.
/// If in-the-wild drift starts slipping past it, the concrete upgrade path is a
/// SwiftSyntax-based implementation that can model expressions and dataflow instead of extending these heuristics.
@MainActor
// swiftlint:disable:next type_body_length
struct ProviderArchitectureGatekeeperTests {
    @Test
    func `every provider has descriptor and implementation manifest entries`() {
        let expected = Set(UsageProvider.allCases)
        let descriptors = Set(ProviderDescriptorRegistry.all.map(\.id))
        let implementations = Set(ProviderCatalog.all.map(\.id))
        let missingDescriptors = expected.subtracting(descriptors).map(\.rawValue).sorted()
        let missingImplementations = expected.subtracting(implementations).map(\.rawValue).sorted()

        #expect(
            missingDescriptors.isEmpty,
            "Missing descriptor manifest entries: \(missingDescriptors.joined(separator: ", "))")
        #expect(
            missingImplementations.isEmpty,
            "Missing implementation manifest entries: \(missingImplementations.joined(separator: ", "))")
    }

    @Test
    func `credential adapters self report capabilities through descriptors`() {
        for descriptor in ProviderDescriptorRegistry.all {
            guard let adapter = descriptor.credentials else { continue }

            #expect(
                ProviderConfigEnvironment.supportsAPIKeyOverride(for: descriptor.id) ==
                    adapter.supportsAPIKeyOverride,
                "API-key capability drifted for \(descriptor.id.rawValue).")
            #expect(
                (TokenAccountSupportCatalog.support(for: descriptor.id) != nil) ==
                    (adapter.tokenAccountSupport != nil),
                "Token-account capability drifted for \(descriptor.id.rawValue).")
        }
    }

    @Test
    func `every provider can produce and read its registered settings section`() {
        let settings = testSettingsStore(suiteName: "ProviderArchitectureGatekeeperTests-settings-sections")
        let context = ProviderSettingsSnapshotContext(settings: settings, tokenOverride: nil)
        var builder = ProviderSettingsSnapshotBuilder()

        for implementation in ProviderCatalog.all {
            let providerName = implementation.id.rawValue
            let registration = ProviderDescriptorRegistry.descriptor(for: implementation.id).settingsSection
            guard let contribution = implementation.settingsSnapshot(context: context) else {
                Issue.record("Missing settings-section contribution for provider '\(providerName)'.")
                continue
            }
            #expect(
                registration.accepts(contribution),
                "Settings-section registration does not match provider '\(providerName)'.")
            builder.apply(contribution)
        }

        let snapshot = builder.build()
        for descriptor in ProviderDescriptorRegistry.all {
            #expect(
                descriptor.settingsSection.canRead(from: snapshot),
                "Could not read settings section for provider '\(descriptor.id.rawValue)'.")
        }
    }

    @Test
    func `empty settings snapshot factory has no provider sections`() {
        let snapshot = ProviderSettingsSnapshot.make()

        #expect(!snapshot.debugMenuEnabled)
        #expect(!snapshot.debugKeepCLISessionsAlive)
    }

    @Test
    func `every provider descriptor has a loadable SVG resource`() throws {
        let resources = try Self.repoRoot()
            .appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)

        for descriptor in ProviderDescriptorRegistry.all {
            let resourceName = descriptor.branding.iconResourceName
            let url = resources.appending(path: "\(resourceName).svg")
            #expect(
                FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
                "Missing SVG for \(descriptor.id.rawValue): \(resourceName).svg")
            #expect(NSImage(contentsOf: url) != nil, "Could not load \(resourceName).svg as NSImage")
        }
    }

    @Test
    func `widget provider choices match selectable descriptor metadata`() {
        let selectable = Set(ProviderDescriptorRegistry.all.filter(\.metadata.widgetSelectable).map(\.id))
        let choices = Set(ProviderChoice.allCases.map(\.provider))
        let missing = selectable.subtracting(choices).map(\.rawValue).sorted()
        let unexpected = choices.subtracting(selectable).map(\.rawValue).sorted()

        #expect(
            missing.isEmpty,
            "Missing ProviderChoice cases for widget-selectable providers: \(missing.joined(separator: ", "))")
        #expect(
            unexpected.isEmpty,
            "ProviderChoice cases marked non-selectable in descriptor metadata: \(unexpected.joined(separator: ", "))")
    }

    @Test
    func `widget short labels preserve compact provider names`() {
        let overrides: [UsageProvider: String] = [:]
        for descriptor in ProviderDescriptorRegistry.all {
            let expected = overrides[descriptor.id] ?? descriptor.metadata.displayName
            #expect(
                descriptor.metadata.shortDisplayName == expected,
                "Unexpected widget short label for \(descriptor.id.rawValue).")
        }
    }

    @Test
    func `descriptor widget colors preserve the audited palette`() {
        var widgetFingerprint: UInt64 = 1_469_598_103_934_665_603
        var burnDownFingerprint = widgetFingerprint
        for descriptor in ProviderDescriptorRegistry.all {
            Self.hash(descriptor.id.rawValue.utf8, into: &widgetFingerprint)
            Self.hash(descriptor.branding.widgetColor, into: &widgetFingerprint)
            Self.hash(descriptor.id.rawValue.utf8, into: &burnDownFingerprint)
            Self.hash(descriptor.branding.burnDownWidgetColor, into: &burnDownFingerprint)
        }

        #expect(widgetFingerprint == 15_064_318_685_957_419_061)
        #expect(burnDownFingerprint == 4_327_412_631_551_192_818)
    }

    @Test
    func `descriptor unavailable debug messages preserve the legacy table`() throws {
        let descriptors = ProviderDescriptorRegistry.all.filter { $0.metadata.debugLogUnavailableMessage != nil }
        var fingerprint: UInt64 = 1_469_598_103_934_665_603
        for descriptor in descriptors {
            Self.hash(descriptor.id.rawValue.utf8, into: &fingerprint)
            try Self.hash(#require(descriptor.metadata.debugLogUnavailableMessage?.utf8), into: &fingerprint)
        }

        #expect(descriptors.count == 1)
        #expect(fingerprint == 6_204_756_619_646_897_441)
    }

    @Test
    func `debug pane provider curation preserves legacy membership and order`() {
        let descriptors = ProviderDescriptorRegistry.all
        let ordered: ((ProviderDebugPaneCapabilities) -> Int?) -> [UsageProvider] = { rank in
            descriptors.compactMap { descriptor -> (UsageProvider, Int)? in
                guard let value = rank(descriptor.metadata.debugPane) else { return nil }
                return (descriptor.id, value)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        }

        #expect(ordered { $0.probeLogOrder } == [.claude])
        #expect(ordered { $0.notificationSimulationOrder } == [.claude])
        #expect(ordered { $0.errorSimulationOrder } == [.claude])
    }

    @Test
    func `small provider capabilities preserve legacy registries`() {
        let descriptors = ProviderDescriptorRegistry.all
        #expect(Set(descriptors.filter(\.metadata.balanceOnly).map(\.id)) == [
            .deepseek,
        ])
        #expect(Set(descriptors.filter(\.metadata.usesDetailBackedWindow).map(\.id)) == [
            .deepseek,
        ])
        #expect(Set(descriptors.filter(\.tokenCost.supportsTokenSnapshot).map(\.id)) == [
            .claude, .opencodego, .devin,
        ])
        #expect(Set(descriptors.filter { $0.cli.binaryLocator != nil }.map(\.id)) == [
            .claude,
        ])
        #expect(descriptors.compactMap { descriptor in
            descriptor.credentials?.apiKeyDebugLabel.map { (descriptor.id, $0) }
        }.map(\.0) == [.opencodego])

        #expect(ClaudeProviderDescriptor.descriptor.tokenCost.menuHintLines == [.estimate])
    }

    @Test
    func `cross provider case clusters are derived or specifically justified`() throws {
        let root = try Self.repoRoot()
        let files = try Self.shippedSwiftSources(root: root)
        let providerIDs = Set(UsageProvider.allCases.map(\.rawValue))
        let providerIDsByFolderName = Dictionary(uniqueKeysWithValues: providerIDs.map { ($0.lowercased(), $0) })
        var failures: [String] = []
        var constructsByPath: [String: [AllowedProviderConstruct]] = [:]
        var suppressionsByPath: [String: [SuppressedProviderReference]] = [:]

        for construct in Self.allowedProviderConstructs {
            constructsByPath[construct.path, default: []].append(construct)
        }
        for suppression in Self.suppressedProviderReferences {
            suppressionsByPath[suppression.path, default: []].append(suppression)
        }

        for file in files {
            let ownedProviderID = Self.providerImplementationID(
                file.path,
                providerIDsByFolderName: providerIDsByFolderName)
            let result = Self.analyze(
                file: file,
                providerIDs: providerIDs.subtracting(ownedProviderID.map { [$0] } ?? []),
                allowedConstructs: constructsByPath.removeValue(forKey: file.path) ?? [],
                suppressedReferences: suppressionsByPath.removeValue(forKey: file.path) ?? [])
            failures.append(contentsOf: result)
        }

        for constructs in constructsByPath.values.flatMap(\.self) {
            failures.append("\(constructs.path): allowlisted construct file does not exist in a shipped Swift target")
        }
        for suppression in suppressionsByPath.values.flatMap(\.self) {
            failures.append("\(suppression.path): suppressed reference file does not exist in a shipped Swift target")
        }

        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    @Test
    func `provider reference scanner catches raw ID policy fallbacks`() {
        let source = #"let command = sender.representedObject as? String ?? "claude""#
        let references = Self.providerReferences(in: source, providerIDs: ["claude", "codex"])

        #expect(references.count == 1)
        #expect(references.first?.providerIDs == ["claude"])
    }

    @Test
    func `provider reference scanner catches labeled and positional arguments`() {
        let source = "let rows = [makeRow(provider: .claude), makeRow(.codex)]"
        let references = Self.providerReferences(in: source, providerIDs: ["claude", "codex"])

        #expect(references.count == 1)
        #expect(references.first?.providerIDs == ["claude", "codex"])
    }

    @Test
    func `provider reference scanner preserves mixed quoted and executable occurrences`() {
        let source = #"let values = [".claude", "escaped \".claude\"", "\(choose(.codex))", "# +
            #".codex, .codex, UsageProvider.cursor, "gemini"]"#
        let references = Self.providerReferences(in: source, providerIDs: ["claude", "codex", "cursor", "gemini"])

        #expect(references == [ProviderReference(
            line: 0,
            providerOccurrences: ["claude", "codex", "codex", "codex", "cursor", "gemini"],
            newlyRecognizedProviderOccurrences: ["codex", "cursor"])])
    }

    @Test
    func `provider candidate prefilter preserves recognized lexical shapes`() {
        let providerIDs: Set = ["claude", "codex", "cursor", "gemini", "foo-bar", "foo.bar", "🦞"]
        let exactDottedCandidates = Self.exactDottedProviderIDCandidates(providerIDs)
        let fixtures: [(source: String, expected: Set<String>)] = [
            ("makeRow(provider: .claude)", ["claude"]),
            ("let provider = UsageProvider.codex", ["codex"]),
            (#"let provider = "cursor""#, ["cursor"]),
            (#"let provider = ".gemini.""#, ["gemini"]),
            (#"let provider = "\(choose(.claude))""#, ["claude"]),
            (#"let url = "https://example.com/codex""#, []),
            ("let value = object.cursorBudget", []),
            ("return .foo-bar", ["foo-bar"]),
            ("return .foo.bar", ["foo.bar"]),
            ("return .🦞", ["🦞"]),
            ("let value = unrelated", []),
        ]

        for fixture in fixtures {
            let literals = Self.quotedStringLiterals(in: fixture.source)
            #expect(Self.providerIDCandidates(
                in: fixture.source,
                quotedLiterals: literals,
                providerIDs: providerIDs,
                exactDottedCandidates: exactDottedCandidates) == fixture.expected)
        }
    }

    @Test
    func `provider reference scanner preserves symbolic provider IDs`() {
        for providerID in ["foo-bar", "foo.bar", "🦞"] {
            let dotted = Self.providerReferences(in: "return .\(providerID)", providerIDs: [providerID])
            let literal = Self.providerReferences(in: "return \"\(providerID)\"", providerIDs: [providerID])
            let suffixed = Self.providerReferences(in: "return .\(providerID)Suffix", providerIDs: [providerID])
            let quoted = Self.providerReferences(
                in: "let value = \"prefix .\(providerID) suffix\"",
                providerIDs: [providerID])

            #expect(dotted.first?.providerIDs == [providerID])
            #expect(literal.first?.providerIDs == [providerID])
            #expect(suffixed.isEmpty)
            #expect(quoted.isEmpty)
        }

        #expect(Self.providerReferences(in: "return .", providerIDs: [""]).first?.providerIDs == [""])
        #expect(Self.providerReferences(in: "return .member", providerIDs: [""]).isEmpty)
        #expect(Self.providerReferences(in: "return \"\"", providerIDs: [""]).isEmpty)
    }

    @Test
    func `provider reference scanner sees through inline block comments`() {
        let assignment = "let provider: UsageProvider = /* fallback */ .claude"
        let labeled = "choose(provider: /* fallback */ .claude)"

        #expect(Self.providerReferences(in: assignment, providerIDs: ["claude"]).count == 1)
        #expect(Self.providerReferences(in: labeled, providerIDs: ["claude"]).count == 1)
    }

    @Test
    func `single provider argument remains an architecture finding`() {
        let failures = Self.analyze(
            file: SourceFile(path: "Sources/App/Shared.swift", source: "makeRow(provider: .claude)"),
            providerIDs: ["claude"],
            allowedConstructs: [])

        #expect(failures.count == 1)
    }

    @Test
    func `provider reference scanner catches fully qualified cases`() {
        let source = "let provider = UsageProvider.claude"
        let references = Self.providerReferences(in: source, providerIDs: ["claude"])

        #expect(references.count == 1)
        #expect(references.first?.providerIDs == ["claude"])
    }

    @Test
    func `provider instance aliases are derived only when names match`() {
        let derived = "public static let claude = UsageProvider.claude.instanceID"
        let policy = "public static let defaultProvider = UsageProvider.claude.instanceID"

        #expect(Self.providerReferences(in: derived, providerIDs: ["claude"]).isEmpty)
        #expect(Self.providerReferences(in: policy, providerIDs: ["claude"]).count == 1)
    }

    @Test
    func `provider reference scanner catches raw IDs in policy contexts`() {
        let source = #"""
        if selected == "claude" { return }
        case "codex": break
        return "cursor"
        route(command: "gemini")
        """#
        let references = Self.providerReferences(
            in: source,
            providerIDs: ["claude", "codex", "cursor", "gemini"])

        #expect(references.map(\.providerIDs) == [["claude"], ["codex"], ["cursor"], ["gemini"]])
    }

    @Test
    func `provider reference scanner catches raw IDs in every single statement position`() {
        let source = #"""
        let choice = "claude"
        choose("claude")
        let aliases = ["primary": "claude"]
        """#
        let references = Self.providerReferences(in: source, providerIDs: ["claude"])

        #expect(references.map(\.providerIDs) == [["claude"], ["claude"], ["claude"]])
    }

    @Test
    func `provider reference scanner catches labeled dotted case on continuation line`() {
        let source = """
        choose(
            provider:
                .claude)
        """
        let references = Self.providerReferences(in: source, providerIDs: ["claude"])

        #expect(references.count == 1)
        #expect(references.first?.providerIDs == ["claude"])
        #expect(references.first?.newlyRecognizedProviderIDs == ["claude"])
    }

    @Test
    func `provider reference scanner catches raw IDs in multiline policy statements`() {
        let source = #"""
        let handlers = [
            "claude": handler,
        ]
        let providerIDs = [
            "codex",
        ]
        """#
        let references = Self.providerReferences(in: source, providerIDs: ["claude", "codex"])

        #expect(references.map(\.providerIDs) == [["claude"], ["codex"]])
    }

    @Test
    func `provider reference scanner includes every multiline statement line in policy context`() {
        let source = #"""
        let aliases = [
            "provider":
                "claude",
        ]
        """#
        let references = Self.providerReferences(in: source, providerIDs: ["claude"])

        #expect(references.map(\.providerIDs) == [["claude"]])
    }

    @Test
    func `provider reference scanner ignores generic URLs and log categories`() {
        let source = #"""
        let url = "https://example.com/claude/status"
        if endpoint == "https://chat.openai.com" { return }
        let log = Logger(subsystem: "com.example.fixture", category: "codex")
        logger.info("claude request completed")
        logger.info(
            "codex request completed"
        )
        """#

        #expect(Self.providerReferences(in: source, providerIDs: ["claude", "codex", "openai"]).isEmpty)
    }

    @Test
    func `URL and log suppression applies only to its literal`() {
        let source = #"""
        let url = "https://example.com/claude"; let provider = "codex"
        logger.info("codex request completed"); return "codex"
        """#
        let references = Self.providerReferences(in: source, providerIDs: ["claude", "codex"])

        #expect(references.map(\.providerIDs) == [["codex"], ["codex"]])
    }

    @Test
    func `log suppression is scoped to the enclosing call argument`() {
        let source = #"""
        logger.info(
            "codex",
            metadata: ["provider": selectedProvider])
        selectProvider("claude", logger: logger.shared)
        selectProvider(
            "claude",
            logger: logger.shared)
        """#
        let references = Self.providerReferences(in: source, providerIDs: ["claude", "codex"])

        #expect(references.map(\.providerIDs) == [["claude"], ["claude"]])
    }

    @Test
    func `category suppression requires a log category constructor`() {
        let source = #"""
        let providerLog = OSLog(
            subsystem: "com.example.fixture",
            category: "codex")
        ProviderRule(category: "claude")
        """#
        let references = Self.providerReferences(in: source, providerIDs: ["claude", "codex"])

        #expect(references.map(\.providerIDs) == [["claude"]])
    }

    @Test
    func `suppression tokens require identifier boundaries`() {
        let source = #"""
        catalog.provider(
            named: "claude")
        catalogger.provider(
            named: "codex")
        render(
            subcategory:
                provider(named: "cursor"))
        """#
        let references = Self.providerReferences(
            in: source,
            providerIDs: ["claude", "codex", "cursor"])

        #expect(references.map(\.providerIDs) == [["claude"], ["codex"], ["cursor"]])
    }

    @Test
    func `exact suppression leaves repeated provider tokens visible`() {
        let path = "Sources/App/Shared.swift"
        let anchor = "let rows = [makeRow(provider: .claude), makeRow(provider: .claude)]"
        let suppression = SuppressedProviderReference(
            path: path,
            anchor: anchor,
            expectedProviderIDs: ["claude"],
            reason: "The fixture suppresses exactly one token.")
        let failures = Self.analyze(
            file: SourceFile(path: path, source: anchor),
            providerIDs: ["claude"],
            allowedConstructs: [],
            suppressedReferences: [suppression])

        #expect(failures.count == 1)
        #expect(failures.first?.contains("references: 1") == true)
    }

    @Test
    func `exact suppression can justify a raw provider ID literal`() {
        let path = "Sources/App/Shared.swift"
        let anchor = "let upstreamStorageDirectory = \"opencode\""
        let suppression = SuppressedProviderReference(
            path: path,
            anchor: anchor,
            expectedProviderIDs: ["opencode"],
            reason: "The fixture models an exact upstream storage contract.")
        let failures = Self.analyze(
            file: SourceFile(path: path, source: anchor),
            providerIDs: ["opencode"],
            allowedConstructs: [],
            suppressedReferences: [suppression])

        #expect(failures.isEmpty)
    }

    @Test
    func `provider implementation path identifies only a real provider folder`() {
        let folders = ["claude": "claude", "codex": "codex"]

        #expect(Self.providerImplementationID(
            "Sources/CodexBar/Providers/Claude/ClaudeSettings.swift",
            providerIDsByFolderName: folders) == "claude")
        #expect(Self.providerImplementationID(
            "Sources/CodexBar/Providers/Shared/ProviderHelpers.swift",
            providerIDsByFolderName: folders) == nil)
        #expect(Self.providerImplementationID(
            "Sources/CodexBar/NotProviders/ClaudeSettings.swift",
            providerIDsByFolderName: folders) == nil)
    }

    @Test
    func `provider folders exempt only their own provider references`() {
        let file = SourceFile(
            path: "Sources/CodexBar/Providers/Claude/ClaudeSettings.swift",
            source: "let providers: [UsageProvider] = [.claude, .codex]")
        let ownedProviderID = Self.providerImplementationID(
            file.path,
            providerIDsByFolderName: ["claude": "claude", "codex": "codex"])
        let failures = Self.analyze(
            file: file,
            providerIDs: Set(["claude", "codex"]).subtracting(ownedProviderID.map { [$0] } ?? []),
            allowedConstructs: [])

        #expect(failures.count == 1)
        #expect(failures.first?.contains("codex") == true)
        #expect(failures.first?.contains("claude") == false)
    }

    @Test
    func `provider clusters cannot chain beyond the fixed window`() {
        let references = [0, 10, 20, 30, 39, 40, 50, 60].map {
            ProviderReference(line: $0, providerIDs: ["codex"])
        }

        #expect(Self.providerReferenceClusters(references).map(\.lineRange) == [0...39, 40...60])
    }

    @Test
    func `one marker cannot justify two provider clusters`() {
        let source = ([
            "// Provider-specific by design: first fallback.",
            "let first = .codex",
        ] + Array(repeating: "", count: 13) + ["let second = .claude"]).joined(separator: "\n")
        let failures = Self.analyze(
            file: SourceFile(path: "Sources/App/Shared.swift", source: source),
            providerIDs: ["claude", "codex"],
            allowedConstructs: [])

        #expect(failures.count == 1)
        #expect(failures.first?.contains(":16 ") == true)
    }

    @Test
    func `provider markers must be comments with reasons`() {
        let stringMarker = #"let text = "Provider-specific by design: not a comment"\nlet value = .codex"#
        let emptyMarker = "// Provider-specific by design:   \nlet value = .codex"
        let validMarker = "// Provider-specific by design: fixture policy.\nlet value = .codex"

        #expect(Self.analyze(
            file: SourceFile(path: "Sources/App/StringMarker.swift", source: stringMarker),
            providerIDs: ["codex"],
            allowedConstructs: []).count == 1)
        #expect(Self.analyze(
            file: SourceFile(path: "Sources/App/EmptyMarker.swift", source: emptyMarker),
            providerIDs: ["codex"],
            allowedConstructs: []).count == 1)
        #expect(Self.analyze(
            file: SourceFile(path: "Sources/App/ValidMarker.swift", source: validMarker),
            providerIDs: ["codex"],
            allowedConstructs: []).isEmpty)
    }

    @Test(arguments: [0, 5])
    func `exact anchors follow unrelated lines above source`(prefixLineCount: Int) {
        let path = "Sources/App/Shared.swift"
        let suppressionAnchor = "let storage = \"opencode\""
        let constructAnchor = "let fallback = .codex"
        let source = String(repeating: "\n", count: prefixLineCount) + suppressionAnchor + "\n" + constructAnchor
        let suppression = SuppressedProviderReference(
            path: path,
            anchor: suppressionAnchor,
            expectedProviderIDs: ["opencode"],
            reason: "The fixture models an upstream storage contract.")
        let construct = AllowedProviderConstruct(
            path: path,
            anchor: constructAnchor,
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["codex@0"],
            reason: "The fixture verifies anchors survive unrelated line shifts.")

        #expect(Self.analyze(
            file: SourceFile(path: path, source: source),
            providerIDs: ["codex", "opencode"],
            allowedConstructs: [construct],
            suppressedReferences: [suppression]).isEmpty)
    }

    @Test
    func `unique anchors resolve by exact trimmed text`() throws {
        let lines = ["", "let fallback = .codexExtra", "\tlet fallback = .codex  ", "// let fallback = .codex"]
        #expect(try Self.resolveAnchorLine("let fallback = .codex", in: lines) == 2)
        #expect(try Self.resolveAnchorLine("let fallback = .codex", in: [""] + lines) == 3)
    }

    @Test
    func `duplicate anchors require a one based occurrence`() throws {
        let lines = ["anchor", "", "  anchor", "anchor"]
        #expect(try Self.resolveAnchorLine("anchor", occurrence: 1, in: lines) == 0)
        #expect(try Self.resolveAnchorLine("anchor", occurrence: 2, in: lines) == 2)
        #expect(try Self.resolveAnchorLine("anchor", occurrence: 3, in: lines) == 3)
        #expect(throws: AnchorResolutionError.ambiguous(matches: 3)) {
            try Self.resolveAnchorLine("anchor", in: lines)
        }
    }

    @Test
    func `missing anchors fail exact resolution`() {
        #expect(throws: AnchorResolutionError.missing) {
            try Self.resolveAnchorLine("anchor", in: ["anchor suffix", "// anchor"])
        }
        #expect(throws: AnchorResolutionError.missing) {
            try Self.resolveAnchorLine("anchor", occurrence: 1, in: [])
        }
    }

    @Test(arguments: [Int.min, -1, 0, 3, Int.max])
    func `anchor occurrences outside the match range fail`(occurrence: Int) {
        #expect(throws: AnchorResolutionError.occurrenceOutOfRange(occurrence: occurrence, matches: 2)) {
            try Self.resolveAnchorLine("anchor", occurrence: occurrence, in: ["anchor", "", "anchor"])
        }
    }

    @Test
    func `suppression duplicates are detected at the resolved line`() {
        let path = "Sources/App/Shared.swift"
        let anchor = "let storage = \"opencode\""
        let suppression = SuppressedProviderReference(
            path: path,
            anchor: anchor,
            expectedProviderIDs: ["opencode"],
            reason: "The fixture suppresses exactly one storage contract.")
        let duplicate = SuppressedProviderReference(
            path: path,
            occurrence: 1,
            anchor: anchor,
            expectedProviderIDs: ["opencode"],
            reason: suppression.reason)
        let failures = Self.analyze(
            file: SourceFile(path: path, source: "\n\n" + anchor),
            providerIDs: ["opencode"],
            allowedConstructs: [],
            suppressedReferences: [suppression, duplicate])

        #expect(failures == ["\(path):3 duplicate suppressed provider reference"])
    }

    @Test
    func `duplicate anchors select only their requested occurrence`() {
        let path = "Sources/App/Shared.swift"
        let anchor = "let fallback = .codex"
        let source = anchor + String(repeating: "\n", count: 14) + anchor
        let suppression = SuppressedProviderReference(
            path: path,
            occurrence: 1,
            anchor: anchor,
            expectedProviderIDs: ["codex"],
            reason: "The fixture suppresses the first reference only.")
        let construct = AllowedProviderConstruct(
            path: path,
            occurrence: 2,
            anchor: anchor,
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["codex@0"],
            reason: "The fixture allowlists the second construct only.")

        #expect(Self.analyze(
            file: SourceFile(path: path, source: source),
            providerIDs: ["codex"],
            allowedConstructs: [construct],
            suppressedReferences: [suppression]).isEmpty)
    }

    @Test
    func `allowlist anchors tolerate at most two lines before a cluster`() {
        let source = ["let anchor = true", "", "", "let fallback = .codex"].joined(separator: "\n")
        let construct = AllowedProviderConstruct(
            path: "Sources/App/Shared.swift",
            anchor: "let anchor = true",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["codex@0"],
            reason: "The fixture verifies anchor distance.")

        #expect(Self.analyze(
            file: SourceFile(path: construct.path, source: source),
            providerIDs: ["codex"],
            allowedConstructs: [construct]).isEmpty == false)
    }

    @Test
    func `allowlisted constructs are unique and fingerprinted`() {
        let source = """
        let fallback = .codex
        """
        let construct = AllowedProviderConstruct(
            path: "Sources/App/Shared.swift",
            anchor: "let fallback = .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["codex@0"],
            reason: "The fixture verifies exact construct matching.")

        #expect(Self.analyze(
            file: SourceFile(path: construct.path, source: source),
            providerIDs: ["codex"],
            allowedConstructs: [construct]).isEmpty)
        #expect(Self.analyze(
            file: SourceFile(path: construct.path, source: source + "\nlet other = .codex"),
            providerIDs: ["codex"],
            allowedConstructs: [construct]).isEmpty == false)
    }

    @Test
    func `allowlist fingerprints preserve repeated occurrences on one line`() {
        let original = "let anchor = true\nlet values = [.codex]"
        let changed = "let anchor = true\nlet values = [.codex, .codex]"
        let construct = AllowedProviderConstruct(
            path: "Sources/App/Shared.swift",
            anchor: "let anchor = true",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["codex@0"],
            reason: "The fixture verifies per-occurrence fingerprints.")

        #expect(Self.analyze(
            file: SourceFile(path: construct.path, source: original),
            providerIDs: ["codex"],
            allowedConstructs: [construct]).isEmpty)
        let failures = Self.analyze(
            file: SourceFile(path: construct.path, source: changed),
            providerIDs: ["codex"],
            allowedConstructs: [construct])
        #expect(failures.count == 2)
        #expect(failures.first?.contains("found [\"codex\"]/2/[\"codex@0\", \"codex@0\"]") == true)
    }

    private struct SourceFile {
        let path: String
        let source: String
    }

    private struct ProviderReference: Equatable {
        let line: Int
        var providerOccurrences: [String]
        var newlyRecognizedProviderOccurrences: [String]

        var providerIDs: Set<String> {
            Set(self.providerOccurrences)
        }

        var newlyRecognizedProviderIDs: Set<String> {
            Set(self.newlyRecognizedProviderOccurrences)
        }

        init(
            line: Int,
            providerIDs: Set<String>,
            newlyRecognizedProviderIDs: Set<String> = [])
        {
            self.line = line
            self.providerOccurrences = providerIDs.sorted()
            self.newlyRecognizedProviderOccurrences = newlyRecognizedProviderIDs.sorted()
        }

        init(
            line: Int,
            providerOccurrences: [String],
            newlyRecognizedProviderOccurrences: [String])
        {
            self.line = line
            self.providerOccurrences = providerOccurrences.sorted()
            self.newlyRecognizedProviderOccurrences = newlyRecognizedProviderOccurrences.sorted()
        }

        mutating func suppressOneOccurrence(of providerID: String) -> Bool {
            guard let occurrenceIndex = self.providerOccurrences.firstIndex(of: providerID) else { return false }
            if let newlyRecognizedIndex = self.newlyRecognizedProviderOccurrences.firstIndex(of: providerID) {
                self.newlyRecognizedProviderOccurrences.remove(at: newlyRecognizedIndex)
            }
            self.providerOccurrences.remove(at: occurrenceIndex)
            return true
        }
    }

    private struct ProviderReferenceCluster {
        let references: [ProviderReference]

        var lineRange: ClosedRange<Int> {
            self.references[0].line...self.references[self.references.count - 1].line
        }

        var providerIDs: Set<String> {
            self.references.reduce(into: []) { $0.formUnion($1.providerIDs) }
        }

        var referenceCount: Int {
            self.references.reduce(0) { $0 + $1.providerOccurrences.count }
        }

        var referenceFingerprint: [String] {
            self.references.flatMap { reference in
                reference.providerOccurrences.sorted().map { "\($0)@\(reference.line - self.lineRange.lowerBound)" }
            }
        }

        var newlyRecognizedFingerprint: [String] {
            self.references.flatMap { reference in
                reference.newlyRecognizedProviderOccurrences.sorted().map {
                    "\($0)@\(reference.line - self.lineRange.lowerBound)"
                }
            }
        }
    }

    private struct SuppressedProviderReference {
        let path: String
        let occurrence: Int?
        let anchor: String
        let expectedProviderIDs: Set<String>
        let reason: String

        init(
            path: String,
            occurrence: Int? = nil,
            anchor: String,
            expectedProviderIDs: Set<String>,
            reason: String)
        {
            self.path = path
            self.occurrence = occurrence
            self.anchor = anchor
            self.expectedProviderIDs = expectedProviderIDs
            self.reason = reason
        }
    }

    private struct AllowedProviderConstruct {
        let path: String
        let occurrence: Int?
        let anchor: String
        let expectedProviderIDs: Set<String>
        let expectedReferenceCount: Int
        let expectedReferenceFingerprint: [String]?
        let reason: String

        init(
            path: String,
            occurrence: Int? = nil,
            anchor: String,
            expectedProviderIDs: Set<String>,
            expectedReferenceCount: Int,
            expectedReferenceFingerprint: [String]? = nil,
            reason: String)
        {
            self.path = path
            self.occurrence = occurrence
            self.anchor = anchor
            self.expectedProviderIDs = expectedProviderIDs
            self.expectedReferenceCount = expectedReferenceCount
            self.expectedReferenceFingerprint = expectedReferenceFingerprint
            self.reason = reason
        }
    }

    private static let providerCaseMarker = "Provider-specific by design:"
    private static let providerCaseMarkerWindow = 40
    private static let providerCaseClusterGap = 12
    private static let providerCaseClusterWindow = 40
    private static let allowlistAnchorTolerance = 2

    // swiftlint:disable line_length
    /// Provider references may be suppressed only at an exact text anchor and for an exact provider set. Each entry
    /// documents why that token is an external contract or ownership data rather than shared provider-selection
    /// policy.
    private static let suppressedProviderReferences: [SuppressedProviderReference] = [
        SuppressedProviderReference(
            path: "Sources/CodexBar/UsageStore+Accessors.swift",
            anchor: "accountID: self.settings.selectedTokenAccount(for: .deepseek)?.id,",
            expectedProviderIDs: ["deepseek"],
            reason: "This provider-specific app branch passes its already-selected identity to a shared helper."),
        SuppressedProviderReference(
            path: "Sources/CodexBar/UsageStore+ClaudeDebug.swift",
            anchor: "for: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "This provider-owned integration passes its fixed identity to a shared helper."),
        SuppressedProviderReference(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            anchor: "let currentAccount = self.uniqueTokenAccount(provider: .claude, accountID: fetchedAccount.id),",
            expectedProviderIDs: ["claude"],
            reason: "This provider-specific app branch passes its already-selected identity to a shared helper."),
        SuppressedProviderReference(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            anchor: "from: self.presentationSnapshot(for: .deepseek))",
            expectedProviderIDs: ["deepseek"],
            reason: "This provider-specific app branch passes its already-selected identity to a shared helper."),
        SuppressedProviderReference(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            anchor: "return self.tokenAccountSnapshotCacheKey(provider: .claude, account: account)",
            expectedProviderIDs: ["claude"],
            reason: "Claude widget quota ownership uses the selected Claude account's isolated snapshot key."),
        SuppressedProviderReference(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "Claude widget quota ownership uses the selected Claude account's isolated snapshot key."),
        SuppressedProviderReference(
            path: "Sources/CodexBar/UsageStore.swift",
            anchor: "provider: .deepseek,",
            expectedProviderIDs: ["deepseek"],
            reason: "This provider-specific app branch passes its already-selected identity to a shared helper."),
        SuppressedProviderReference(
            path: "Sources/CodexBar/UsageStore.swift",
            anchor: "let sourceMode = self.sourceMode(for: .claude)",
            expectedProviderIDs: ["claude"],
            reason: "This provider-specific app branch passes its already-selected identity to a shared helper."),
        SuppressedProviderReference(
            path: "Sources/CodexBar/UsageStore.swift",
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "This provider-specific app branch passes its already-selected identity to a shared helper."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCLI/CLICardsRenderer.swift",
            occurrence: 2,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "This provider-specific app branch passes its already-selected identity to a shared helper."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCLI/CLICardsRenderer.swift",
            anchor: "title: ProviderDescriptorRegistry.descriptor(for: .claude).metadata.displayName,",
            expectedProviderIDs: ["claude"],
            reason: "This provider-specific app branch passes its already-selected identity to a shared helper."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/ProviderStorageFootprint.swift",
            occurrence: 1,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "This inventory row records the provider that owns its static storage location."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/ProviderStorageFootprint.swift",
            occurrence: 2,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "This inventory row records the provider that owns its static storage location."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/ProviderStorageFootprint.swift",
            occurrence: 3,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "This inventory row records the provider that owns its static storage location."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/ProviderStorageFootprint.swift",
            occurrence: 4,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "This inventory row records the provider that owns its static storage location."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/ProviderStorageFootprint.swift",
            occurrence: 5,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "This inventory row records the provider that owns its static storage location."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/ProviderStorageFootprint.swift",
            occurrence: 6,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "This inventory row records the provider that owns its static storage location."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/ProviderStorageFootprint.swift",
            occurrence: 7,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "This inventory row records the provider that owns its static storage location."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/ProviderStorageFootprint.swift",
            occurrence: 8,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            reason: "This inventory row records the provider that owns its static storage location."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/AgentSession.swift",
            occurrence: 1,
            anchor: ".appendingPathComponent(\".claude\", isDirectory: true)",
            expectedProviderIDs: ["claude"],
            reason: "The Claude transcript locator follows Claude Code's fixed default projects directory."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/AgentSession.swift",
            occurrence: 2,
            anchor: ".appendingPathComponent(\".claude\", isDirectory: true)",
            expectedProviderIDs: ["claude"],
            reason: "The budgeted Claude transcript locator follows Claude Code's fixed default projects directory."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/Providers/ProviderVersionDetector.swift",
            anchor: "return whichHook(\"claude\") != nil",
            expectedProviderIDs: ["claude"],
            reason: "The Claude binary resolvability check asks its injected locator for the fixed executable name."),
        SuppressedProviderReference(
            path: "Sources/CodexBarCore/Providers/ProviderVersionDetector.swift",
            anchor: "? self.whichHook!(\"claude\")",
            expectedProviderIDs: ["claude"],
            reason: "The Claude version detector asks its injected locator for the fixed Claude executable name."),
    ]

    /// Each entry names one uniquely anchored construct and pins its complete provider-reference fingerprint.
    /// Adding or removing a reference invalidates the entry instead of silently expanding an exemption.
    /// Anchors match trimmed source lines exactly; repeated text requires a 1-based occurrence.
    private static let allowedProviderConstructs: [AllowedProviderConstruct] = [
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+Costs.swift",
            anchor: "showsInProviderDetails: style != .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 4,
            expectedReferenceFingerprint: ["claude@0", "claude@2", "claude@3", "claude@8"],
            reason: "Shared cost formatting preserves Claude balance, visibility, fill preference and cloud-credit policy."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            anchor: "style: .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "The monthly cap metric reuses Claude's currency caption instead of duplicating cost formatting."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+Costs.swift",
            anchor: "if style == .apiSpend || (style == .claude && isClaudeAdminAPI) {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@10"],
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            anchor: "if input.provider == .deepseek, let detail = presentation.detailText {",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["deepseek@0"],
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PredictivePaceWarnings.swift",
            anchor: "for (key, prior) in self.quotaWarningState where key.provider == .claude && key.accountDiscriminator == owner {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "Verified Claude history ownership reconciles warning state without sharing it between accounts."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/Providers/Shared/ProviderTokenAccountSelection.swift",
            anchor: "guard provider == .deepseek else { return settings.showOptionalCreditsAndExtraUsage }",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["deepseek@0"],
            reason: "This exact shared provider integration dispatches a capability owned by the provider descriptor or adapter."),

        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+LimitResetCelebration.swift",
            anchor: "let requiresLowConfirmation = context.provider == .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "Identity-less Claude weekly samples share a detector key and require low-sample confirmation."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            anchor: "let detectorAccountKey = if provider == .claude, isClaudeOAuthSample {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@9"],
            reason: "Claude OAuth history requires corroborated ownership before reset detection or persistence."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            occurrence: 2,
            anchor: "if provider == .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            anchor: "guard let identity = snapshot.identity(for: .claude) else { return nil }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 3,
            expectedReferenceFingerprint: ["claude@0", "claude@9", "claude@9"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            anchor: "key.hasPrefix(\"\\(UsageProvider.claude.rawValue):\")",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+QuotaWarnings.swift",
            anchor: "guard provider != .claude || window != .session || Self.isSessionWindow(rateWindow) else { return }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@5"],
            reason: "Claude preserves session history across weekly promotion and reconciles unresolved warning owners."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            anchor: "let priorClaudeSourceLabel = provider == .claude ? self.lastSourceLabels[.claude] : nil",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            anchor: "guard input.provider == .claude else {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            anchor: "let isClaudeOAuthSample = provider == .claude && result.strategyKind == .oauth",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            anchor: "guard provider == .claude, !hasSelectedTokenAccount else { return false }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            occurrence: 2,
            anchor: "if provider == .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            occurrence: 3,
            anchor: "if provider == .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 5,
            expectedReferenceFingerprint: ["claude@0", "claude@11", "claude@19", "claude@28", "claude@37"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            anchor: "cached.cacheKey == self.tokenAccountSnapshotCacheKey(provider: .claude, account: currentAccount)",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            anchor: "provider == .deepseek",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["deepseek@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            anchor: "accountDiscriminatorOverride: provider == .claude ? warningAccountDiscriminator : nil)",
            expectedProviderIDs: ["claude", "deepseek"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "deepseek@4"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            occurrence: 2,
            anchor: "if provider == .deepseek {",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["deepseek@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            anchor: "} else if provider == .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@5"],
            reason: "The widget quota owner follows the active Claude swap account when the adapter owns presentation."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            anchor: "(provider == .claude && (tokenSnapshot != nil || preservedClaudeUsage != nil))",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            anchor: "if let account = self.settings.effectiveSelectedTokenAccount(for: .claude) {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            anchor: "guard var entry, entry.provider == .claude else { return nil }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            anchor: "if provider == .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore.swift",
            anchor: "let claudeDebugConfiguration: ClaudeDebugLogConfiguration? = if provider == .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore.swift",
            anchor: "let deepSeekHasTokenAccount = self.settings.selectedTokenAccount(for: .deepseek) != nil",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["deepseek@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore.swift",
            anchor: "let claudeSettings = snapshot.claude ?? ProviderSettingsSnapshot.ClaudeProviderSettings(",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCLI/CLICostCommand.swift",
            anchor: "if includeBreakdown, provider == .claude || provider == .opencodego, !snapshot.daily.isEmpty {",
            expectedProviderIDs: ["claude", "opencodego"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "opencodego@0"],
            reason: "Claude and OpenCode Go expose daily and per-model local history in the shared CLI renderer."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/AgentSession.swift",
            anchor: "return AgentSession.Provider.claude.rawValue",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact host integration normalizes the Claude Desktop wrapper to its agent provider name."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/AgentSession.swift",
            anchor: "AgentProcessPath.basename($0) == AgentSession.Provider.claude.rawValue",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact host integration strips the Claude executable from normalized process arguments."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/LocalAgentSessionScanner.swift",
            anchor: "let claudeProcesses = processes.filter { AgentPSOutputParser.provider(for: $0) == .claude }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact host integration maps a provider-owned process, path, or window contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/UsageSnapshot+SwitcherWeeklyWindow.swift",
            anchor: "case .claude:",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@8"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift",
            anchor: "if self.claude[base] != nil {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift",
            anchor: "guard let pricing = self.claude[key] else { return nil }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            anchor: "if input.provider == .claude, input.snapshot?.dataConfidence == .percentOnly {",
            expectedProviderIDs: ["claude", "opencodego"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "opencodego@6"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Animation.swift",
            anchor: "let balanceOnly = provider == .deepseek",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["deepseek@0"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MenuTracking.swift",
            anchor: "if target == .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            anchor: "if provider == .claude, isClaudeOAuthSample, let owner = claudeOAuthHistoryOwnerIdentifier {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+QuotaWarnings.swift",
            anchor: "let extraWindows = provider == .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            occurrence: 1,
            anchor: "if provider == .deepseek {",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["deepseek@0"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            occurrence: 1,
            anchor: "if provider == .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+SessionEquivalents.swift",
            anchor: "if provider == .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            occurrence: 1,
            anchor: "case .opencodego:",
            expectedProviderIDs: ["opencodego"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["opencodego@0"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CostUsageFetcher.swift",
            anchor: "if provider == .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Providers/Devin/DevinLocalCostReader.swift",
            anchor: "return .claude(candidate)",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Providers/Devin/DevinLocalCostReader.swift",
            anchor: "case let .claude(normalized):",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift",
            occurrence: 1,
            anchor: "\"deepseek\",",
            expectedProviderIDs: ["deepseek", "opencode"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["deepseek@0", "opencode@4"],
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/ModelsDevPricingTargetResolver.swift",
            anchor: "providerIDs.append(\"opencode\")",
            expectedProviderIDs: ["opencode"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["opencode@0"],
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuBarLayout.swift",
            anchor: "let presentation = ProviderDescriptorRegistry.descriptor(for: provider ?? .claude).presentation",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuBarLayoutEditor.swift",
            anchor: "let provider = self.provider ?? .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuBarLayoutNativeProof.swift",
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@4"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+LimitResetCredits.swift",
            anchor: "guard input.provider == .claude, let resetCredits = input.snapshot?.claudeResetCredits else { return nil }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            anchor: "if input.provider == .claude, input.showOptionalCreditsAndExtraUsage,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@8"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuDescriptor.swift",
            anchor: "return .switchAccount(.claude)",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 9,
            expectedReferenceFingerprint: [
                "claude@0",
                "claude@4",
                "claude@11",
                "claude@12",
                "claude@18",
                "claude@20",
                "claude@21",
                "claude@21",
                "claude@22",
            ],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PredictivePaceWarnings.swift",
            anchor: "guard provider == .claude else { return }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesDebugPane.swift",
            anchor: "@State private var currentLogProvider: UsageProvider = .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 3,
            expectedReferenceFingerprint: ["claude@0", "claude@1", "claude@8"],
            reason: "Claude is the primary provider, so it is the fallback when no other provider resolves."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesProvidersPane+Testing.swift",
            anchor: "store.versions[.claude] = \"2.0.0 (build 123)\"",
            expectedProviderIDs: ["claude", "opencode", "opencodego"],
            expectedReferenceCount: 10,
            expectedReferenceFingerprint: [
                "claude@0",
                "claude@3",
                "claude@4",
                "claude@12",
                "claude@13",
                "opencode@14",
                "opencodego@15",
                "claude@17",
                "claude@27",
                "claude@32",
            ],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesProvidersPane+Testing.swift",
            occurrence: 2,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This test-only app seam pins Codex fixture data and does not make production routing policy."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesProvidersPane.swift",
            anchor: "provider: UsageProvider = .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/ProviderUsageItemVisibility.swift",
            anchor: "if self.provider == .claude, self.limitResetCredits != nil {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            occurrence: 1,
            anchor: "let provider = preferred ?? .claude",
            expectedProviderIDs: ["claude", "opencodego"],
            expectedReferenceCount: 3,
            expectedReferenceFingerprint: ["claude@0", "opencodego@10", "claude@15"],
            reason: "Claude is the primary provider, so it is the fallback when no other provider resolves."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            anchor: "self.openStatusPage(for: preferred ?? .claude)",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@6"],
            reason: "Claude is the primary provider, so it is the fallback when no other provider resolves."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            occurrence: 2,
            anchor: "let provider = preferred ?? .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@8"],
            reason: "Claude is the primary provider, so it is the fallback when no other provider resolves."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            occurrence: 2,
            anchor: "?? .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            anchor: "self.lazyStatusItem(for: provider ?? .claude)",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            anchor: "return .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MemoryPressure.swift",
            anchor: "scope: UsageProvider.claude.rawValue,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@8"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Menu.swift",
            anchor: "self.lastMenuProvider = (resolvedProvider ?? .claude).instanceID",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 3,
            expectedReferenceFingerprint: ["claude@0", "claude@7", "claude@10"],
            reason: "Claude is the primary provider, so it is the fallback when no other provider resolves."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Menu.swift",
            anchor: "let currentProvider = selectedProvider ?? enabledProviders.first ?? .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "Claude is the primary provider, so it is the fallback when no other provider resolves."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Menu.swift",
            anchor: "return .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "Claude is the primary provider, so it is the fallback when no other provider resolves."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Menu.swift",
            anchor: "return self.store.enabledFirstPartyProvidersForDisplay().first ?? .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MenuSwitcher.swift",
            anchor: "let fallbackProviderID = (self.resolvedMenuProvider(enabledProviders: enabledProviders) ?? .claude).instanceID",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MenuSwitcherWarmup.swift",
            anchor: "let currentProvider = selectedProvider ?? enabledProviders.first ?? .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MenuTypes.swift",
            anchor: "self.store.enabledProviders().isEmpty && self.menuBarEligibleProviders().isEmpty ? .claude : nil",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MenuViewportRestore.swift",
            anchor: "return .provider((self.resolvedMenuProvider() ?? .claude).instanceID)",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+ProviderNavigation.swift",
            anchor: "self.navigationResolvedProvider(enabledProviders: enabledProviders) ?? .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@9"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+ProviderNavigation.swift",
            anchor: "return .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Accessors.swift",
            anchor: "case .claude:",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+LimitResetCelebration.swift",
            anchor: "let isClaudeWeekly = input.provider == .claude && input.seriesName == .weekly",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "Claude and Codex weekly resets use distinct confirmation evidence in the shared detector."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            occurrence: 1,
            anchor: "if provider != .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            anchor: "&& !(provider == .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@6"],
            reason: "Claude is the primary provider, so it is the fallback when no other provider resolves."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            occurrence: 2,
            anchor: "if provider != .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            anchor: "if provider == .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            anchor: "if provider == .deepseek,",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["deepseek@0", "deepseek@8"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            anchor: "guard provider == .deepseek else { return snapshot }",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["deepseek@0", "deepseek@1"],
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+SessionEquivalents.swift",
            anchor: "guard provider != .claude else { return true }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            anchor: "if provider == .claude, let directory = self.claudeTokenCostConfigDirectory {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            anchor: "self.tokenFailureGates[.claude]?.reset()",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "The widget quota owner follows the active Claude swap account when the adapter owns presentation."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            anchor: "let providerCost: ProviderCostSnapshot? = if provider == .devin,",
            expectedProviderIDs: ["deepseek", "devin"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["devin@0", "deepseek@9"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore.swift",
            anchor: "return .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "Claude is the primary provider, so it is the fallback when no other provider resolves."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/AgentSession.swift",
            anchor: "if basename == AgentSession.Provider.claude.rawValue {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 5,
            expectedReferenceFingerprint: ["claude@0", "claude@3", "claude@11", "claude@23", "claude@29"],
            reason: "This exact host integration maps a provider-owned process, path, or window contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CostUsageFetcher.swift",
            anchor: "if provider == .opencodego {",
            expectedProviderIDs: ["opencodego"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["opencodego@0"],
            reason: "Codex project totals must merge native-ledger and Pi contributions before publishing the report."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CostUsageFetcher.swift",
            anchor: "options.provider == .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "Claude is the primary provider, so it is the fallback when no other provider resolves."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CostUsageFetcher.swift",
            anchor: "guard provider == .claude else { return nil }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/LocalAgentSessionScanner.swift",
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/ProviderStorageFootprint.swift",
            anchor: "case .claude:",
            expectedProviderIDs: ["claude", "opencode", "opencodego"],
            expectedReferenceCount: 4,
            expectedReferenceFingerprint: ["claude@0", "claude@4", "opencode@14", "opencodego@14"],
            reason: "This exact provider-owned construct passes a fixed identity to shared infrastructure."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/BurnDownWidgetProvider.swift",
            occurrence: 1,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This WidgetKit default or preview pins the established Codex sample provider."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/BurnDownWidgetProvider.swift",
            occurrence: 2,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This WidgetKit default or preview pins the established Codex sample provider."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            occurrence: 1,
            anchor: "@Parameter(title: \"Provider\", default: .claude)",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@4"],
            reason: "This WidgetKit default or preview pins the established Codex sample provider."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            occurrence: 2,
            anchor: "@Parameter(title: \"Provider\", default: .claude)",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@7"],
            reason: "This WidgetKit default or preview pins the established Codex sample provider."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            occurrence: 1,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This WidgetKit default or preview pins the established Codex sample provider."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            anchor: "provider: providers.first ?? .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact WidgetKit construct preserves its compile-time provider selection contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            anchor: "let selected = providers.first { $0.instanceID == stored } ?? providers.first ?? .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This exact WidgetKit construct preserves its compile-time provider selection contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            anchor: "return supported.isEmpty ? [.claude] : supported",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            expectedReferenceFingerprint: ["claude@0", "claude@8"],
            reason: "This exact WidgetKit construct preserves its compile-time provider selection contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            occurrence: 3,
            anchor: "provider: .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            expectedReferenceFingerprint: ["claude@0"],
            reason: "This WidgetKit default or preview pins the established Codex sample provider."),
    ]
    // swiftlint:enable line_length

    private static func shippedSwiftSources(root: URL) throws -> [SourceFile] {
        var files: [SourceFile] = []
        for directoryName in ["Sources", "WidgetExtension"] {
            let directory = root.appending(path: directoryName, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { continue }
            let enumerator = try #require(FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                try files.append(SourceFile(path: path, source: String(contentsOf: url, encoding: .utf8)))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func providerImplementationID(
        _ path: String,
        providerIDsByFolderName: [String: String]) -> String?
    {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 5,
              components[0] == "Sources",
              components[2] == "Providers"
        else { return nil }
        return providerIDsByFolderName[components[3].lowercased()]
    }

    private enum AnchorResolutionError: Error, Equatable, CustomStringConvertible {
        case missing
        case ambiguous(matches: Int)
        case occurrenceOutOfRange(occurrence: Int, matches: Int)

        var description: String {
            switch self {
            case .missing:
                "no longer matches"
            case let .ambiguous(matches):
                "matches \(matches) lines; specify a 1-based occurrence for"
            case let .occurrenceOutOfRange(occurrence, matches):
                "occurrence \(occurrence) is outside 1...\(matches) for"
            }
        }
    }

    private static func resolveAnchorLine(
        _ anchor: String,
        occurrence: Int? = nil,
        in lines: [String]) throws(AnchorResolutionError) -> Int
    {
        let matches = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == anchor }
        guard let first = matches.first else { throw .missing }
        if let occurrence {
            guard (1...matches.count).contains(occurrence) else {
                throw .occurrenceOutOfRange(occurrence: occurrence, matches: matches.count)
            }
            return matches[occurrence - 1]
        }
        guard matches.count == 1 else { throw .ambiguous(matches: matches.count) }
        return first
    }

    private static func analyze(
        file: SourceFile,
        providerIDs: Set<String>,
        allowedConstructs: [AllowedProviderConstruct],
        suppressedReferences: [SuppressedProviderReference] = []) -> [String]
    {
        let lines = file.source.components(separatedBy: .newlines)
        var references = self.providerReferences(in: file.source, providerIDs: providerIDs)
        var failures: [String] = []
        var usedSuppressions: Set<String> = []
        for suppression in suppressedReferences {
            guard suppression.path == file.path else {
                failures.append("\(suppression.path): suppressed reference was assigned to the wrong file")
                continue
            }
            guard !suppression.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failures.append("\(file.path): suppressed reference '\(suppression.anchor)' has no written reason")
                continue
            }
            let line: Int
            do {
                line = try self.resolveAnchorLine(suppression.anchor, occurrence: suppression.occurrence, in: lines)
            } catch {
                failures.append("\(file.path): suppressed reference anchor \(error) '\(suppression.anchor)'")
                continue
            }
            let key = "\(line):\(suppression.expectedProviderIDs.sorted())"
            guard usedSuppressions.insert(key).inserted else {
                failures.append("\(file.path):\(line + 1) duplicate suppressed provider reference")
                continue
            }
            guard let referenceIndex = references.firstIndex(where: {
                $0.line == line && $0.providerIDs.isSuperset(of: suppression.expectedProviderIDs)
            }) else {
                failures.append(
                    "\(file.path):\(line + 1) suppressed provider reference no longer matches " +
                        "\(suppression.expectedProviderIDs.sorted())")
                continue
            }
            for providerID in suppression.expectedProviderIDs.sorted() {
                guard references[referenceIndex].suppressOneOccurrence(of: providerID) else {
                    failures.append(
                        "\(file.path):\(line + 1) suppressed provider token no longer matches \(providerID)")
                    break
                }
            }
        }
        references.removeAll { $0.providerOccurrences.isEmpty }
        let clusters = self.providerReferenceClusters(references)
        let markerLines = lines.indices.filter { self.providerMarkerReason(in: lines[$0]) != nil }
        var allowedClusterIndices: Set<Int> = []

        for construct in allowedConstructs {
            guard construct.path == file.path else {
                failures.append("\(construct.path): allowlisted construct was assigned to the wrong file")
                continue
            }
            guard !construct.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failures.append("\(file.path): allowlisted construct '\(construct.anchor)' has no written reason")
                continue
            }
            let anchorLine: Int
            do {
                anchorLine = try self.resolveAnchorLine(construct.anchor, occurrence: construct.occurrence, in: lines)
            } catch {
                failures.append("\(file.path): allowlisted construct anchor \(error) '\(construct.anchor)'")
                continue
            }
            let candidateIndices = clusters.indices.filter { index in
                let range = clusters[index].lineRange
                return range
                    .contains(anchorLine) ||
                    (anchorLine < range.lowerBound && range.lowerBound - anchorLine <= self.allowlistAnchorTolerance)
            }
            guard candidateIndices.count == 1, let clusterIndex = candidateIndices.first else {
                failures.append(
                    "\(file.path):\(anchorLine + 1) allowlisted construct anchor did not identify exactly one cluster")
                continue
            }
            let cluster = clusters[clusterIndex]
            guard let expectedReferenceFingerprint = construct.expectedReferenceFingerprint else {
                failures.append(
                    "\(file.path):\(anchorLine + 1) allowlisted construct has no occurrence fingerprint; " +
                        "expectedReferenceFingerprint: \(cluster.referenceFingerprint)")
                continue
            }
            guard cluster.providerIDs == construct.expectedProviderIDs,
                  cluster.referenceCount == construct.expectedReferenceCount,
                  cluster.referenceFingerprint == expectedReferenceFingerprint
            else {
                failures.append(
                    "\(file.path):\(cluster.lineRange.lowerBound + 1) allowlisted construct fingerprint changed; " +
                        "expected \(construct.expectedProviderIDs.sorted())/\(construct.expectedReferenceCount)/" +
                        "\(expectedReferenceFingerprint), found \(cluster.providerIDs.sorted())/" +
                        "\(cluster.referenceCount)/\(cluster.referenceFingerprint)")
                continue
            }
            guard allowedClusterIndices.insert(clusterIndex).inserted else {
                failures.append("\(file.path):\(anchorLine + 1) multiple allowlist entries target the same construct")
                continue
            }
        }

        var usedMarkers: Set<Int> = []
        var previousClusterEnd = -1
        for (index, cluster) in clusters.enumerated() where !allowedClusterIndices.contains(index) {
            let lowerBound = max(previousClusterEnd + 1, cluster.lineRange.lowerBound - self.providerCaseMarkerWindow)
            let marker = markerLines.last { line in
                lowerBound...cluster.lineRange.lowerBound ~= line && !usedMarkers.contains(line)
            }
            if let marker {
                usedMarkers.insert(marker)
            } else {
                failures.append(
                    "\(file.path):\(cluster.lineRange.lowerBound + 1) has an unjustified provider-specific " +
                        "construct (\(cluster.providerIDs.sorted().joined(separator: ", ")); " +
                        "references: \(cluster.referenceCount); fingerprint: \(cluster.referenceFingerprint)); " +
                        "newly recognized: \(cluster.newlyRecognizedFingerprint); derive it or add " +
                        "'// Provider-specific by design: <specific reason>' immediately before this cluster.")
            }
            previousClusterEnd = cluster.lineRange.upperBound
        }

        return failures
    }

    private static func providerReferenceClusters(
        _ references: [ProviderReference]) -> [ProviderReferenceCluster]
    {
        self.unfilteredProviderReferenceClusters(references)
    }

    private static func unfilteredProviderReferenceClusters(
        _ references: [ProviderReference]) -> [ProviderReferenceCluster]
    {
        guard let first = references.first else { return [] }
        var clusters: [ProviderReferenceCluster] = []
        var current = [first]
        var clusterStart = first.line
        var previous = first.line

        for reference in references.dropFirst() {
            if reference.line - previous > self.providerCaseClusterGap ||
                reference.line - clusterStart >= self.providerCaseClusterWindow
            {
                clusters.append(ProviderReferenceCluster(references: current))
                current = [reference]
                clusterStart = reference.line
            } else {
                current.append(reference)
            }
            previous = reference.line
        }
        clusters.append(ProviderReferenceCluster(references: current))
        return clusters
    }

    private static func providerReferences(in source: String, providerIDs: Set<String>) -> [ProviderReference] {
        let lines = source.components(separatedBy: .newlines)
        let statementContexts = self.statementContexts(for: lines)
        let exactDottedCandidates = self.exactDottedProviderIDCandidates(providerIDs)
        return lines.enumerated().flatMap { index, line -> [ProviderReference] in
            let code = self.codeBeforeLineComment(line)
            guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            let quotedLiterals = self.quotedStringLiterals(in: code)
            let providerIDCandidates = self.providerIDCandidates(
                in: code,
                quotedLiterals: quotedLiterals,
                providerIDs: providerIDs,
                exactDottedCandidates: exactDottedCandidates)
            let plainStringRanges = quotedLiterals.compactMap { literal -> Range<String.Index>? in
                code[literal.range].contains("\\(") ? nil : literal.range
            }
            var matches: [String] = []
            var newlyRecognizedMatches: [String] = []
            for providerID in providerIDs where providerIDCandidates.contains(providerID) {
                for strength in self.dottedProviderReferenceStrengths(
                    providerID,
                    in: code,
                    plainStringRanges: plainStringRanges,
                    statement: statementContexts[index])
                {
                    matches.append(providerID)
                    if strength != .strong {
                        newlyRecognizedMatches.append(providerID)
                    }
                }
            }
            for literal in quotedLiterals {
                let normalizedLiteral = literal.value.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard providerIDCandidates.contains(normalizedLiteral),
                      self.isProviderIDLiteral(
                          normalizedLiteral,
                          literal: literal.value,
                          range: literal.range,
                          line: code,
                          statement: statementContexts[index])
                else { continue }
                matches.append(normalizedLiteral)
            }
            guard !matches.isEmpty else { return [] }
            return [ProviderReference(
                line: index,
                providerOccurrences: matches,
                newlyRecognizedProviderOccurrences: newlyRecognizedMatches)]
        }
    }

    private static func exactDottedProviderIDCandidates(
        _ providerIDs: Set<String>) -> [(providerID: String, needle: String)]
    {
        providerIDs.compactMap { providerID in
            guard providerID.isEmpty || providerID.contains(where: { !self.isIdentifierCharacter($0) }) else {
                return nil
            }
            return (providerID, ".\(providerID)")
        }
    }

    private static func providerIDCandidates(
        in line: String,
        quotedLiterals: [QuotedStringLiteral],
        providerIDs: Set<String>,
        exactDottedCandidates: [(providerID: String, needle: String)]) -> Set<String>
    {
        var candidates: Set<String> = []
        var searchStart = line.startIndex
        while let dot = line[searchStart...].firstIndex(of: ".") {
            let identifierStart = line.index(after: dot)
            var identifierEnd = identifierStart
            while identifierEnd < line.endIndex, self.isIdentifierCharacter(line[identifierEnd]) {
                identifierEnd = line.index(after: identifierEnd)
            }
            if identifierStart < identifierEnd {
                let identifier = String(line[identifierStart..<identifierEnd])
                if providerIDs.contains(identifier) {
                    candidates.insert(identifier)
                }
            }
            searchStart = identifierEnd
        }

        // This is only candidate admission. The unchanged dotted scanner below rechecks plain-string ranges,
        // identifier boundaries, and policy positions before producing a reference.
        for candidate in exactDottedCandidates where line.contains(candidate.needle) {
            candidates.insert(candidate.providerID)
        }

        for literal in quotedLiterals {
            let normalizedLiteral = literal.value.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if providerIDs.contains(normalizedLiteral) {
                candidates.insert(normalizedLiteral)
            }
        }
        return candidates
    }

    private enum ProviderReferenceStrength: Equatable {
        case strong
        case weakArgument
        case fullyQualified
    }

    private static func dottedProviderReferenceStrengths(
        _ rawValue: String,
        in line: String,
        plainStringRanges: [Range<String.Index>],
        statement: StatementContext) -> [ProviderReferenceStrength]
    {
        let needle = ".\(rawValue)"
        var searchStart = line.startIndex
        var found: [ProviderReferenceStrength] = []
        while let range = line.range(of: needle, range: searchStart..<line.endIndex) {
            if plainStringRanges.contains(where: { $0.contains(range.lowerBound) }) {
                searchStart = range.upperBound
                continue
            }
            if range.upperBound == line.endIndex || !Self.isIdentifierCharacter(line[range.upperBound]),
               let strength = self.providerPolicyPosition(
                   rawValue,
                   range: range,
                   line: line,
                   statement: statement)
            {
                found.append(strength)
            }
            searchStart = range.upperBound
        }
        return found
    }

    private static func providerPolicyPosition(
        _ rawValue: String,
        range: Range<String.Index>,
        line: String,
        statement: StatementContext) -> ProviderReferenceStrength?
    {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let suffix = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("case ") || trimmed.hasPrefix("switch ") ||
            trimmed.hasPrefix("if ") || trimmed.hasPrefix("guard ") ||
            trimmed.hasPrefix("else if ") || trimmed.hasPrefix("return .\(rawValue)")
        {
            return .strong
        }
        if ["==", "!=", "??", " ? ", ".contains(", ".filter", "rawValue"]
            .contains(where: line.contains)
        {
            return .strong
        }
        if prefix.isEmpty, suffix.hasPrefix(":") || suffix.hasPrefix(",") || suffix.isEmpty {
            return .strong
        }
        if prefix.hasSuffix("=") || prefix.hasSuffix("[") || prefix.hasSuffix(",") {
            return .strong
        }
        let qualifier = prefix.split(whereSeparator: { !Self.isIdentifierCharacter($0) }).last.map(String.init)
        if qualifier == "UsageProvider" {
            let derivedInstanceAlias = "public static let \(rawValue) = UsageProvider.\(rawValue).instanceID"
            if trimmed == derivedInstanceAlias {
                return nil
            }
            return .fullyQualified
        }
        if prefix.hasSuffix(":") || prefix.hasSuffix("(") {
            return .weakArgument
        }
        if prefix.isEmpty {
            let statementPrefix = statement.prefixBeforeLine
            if self.unmatchedOpeningParentheses(in: statementPrefix).reversed().contains(where: {
                self.currentArgumentLabel(openingParenthesis: $0, in: statementPrefix) != nil
            }) {
                return .weakArgument
            }
        }
        return suffix.hasPrefix(":") ? .strong : nil
    }

    private struct StatementContext {
        let prefixBeforeLine: String
    }

    private static func isProviderIDLiteral(
        _ providerID: String,
        literal: String,
        range: Range<String.Index>,
        line: String,
        statement: StatementContext) -> Bool
    {
        let lowercasedLiteral = literal.lowercased()
        guard self.containsWord(providerID, in: lowercasedLiteral) else { return false }
        if self.containsSuppressionToken("http://", in: lowercasedLiteral) ||
            self.containsSuppressionToken("https://", in: lowercasedLiteral)
        {
            return false
        }
        if self.isLogLiteral(range: range, in: line, statement: statement) {
            return false
        }
        if literal != lowercasedLiteral {
            return false
        }
        let normalizedLiteral = lowercasedLiteral.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard normalizedLiteral == providerID else { return false }
        return true
    }

    private static func isLogLiteral(
        range: Range<String.Index>,
        in line: String,
        statement: StatementContext) -> Bool
    {
        let prefix = statement.prefixBeforeLine + line[..<range.lowerBound]
        let activePrefix = prefix.split(separator: ";", omittingEmptySubsequences: false).last
            .map(String.init) ?? prefix
        let openingParentheses = self.unmatchedOpeningParentheses(in: activePrefix)
        if openingParentheses.reversed().contains(where: {
            self.isLoggingCall(openingParenthesis: $0, in: activePrefix)
        }) {
            return true
        }
        guard let openingParenthesis = openingParentheses.last,
              self.currentArgumentLabel(openingParenthesis: openingParenthesis, in: activePrefix) == "category"
        else {
            return false
        }
        return self.isLogCategoryConstructor(openingParenthesis: openingParenthesis, in: activePrefix)
    }

    private static func unmatchedOpeningParentheses(in text: String) -> [String.Index] {
        var openingParentheses: [String.Index] = []
        var previous: Character?
        var isInsideString = false
        for index in text.indices {
            let character = text[index]
            if character == "\"", previous != "\\" {
                isInsideString.toggle()
            } else if !isInsideString {
                if character == "(" {
                    openingParentheses.append(index)
                } else if character == ")" {
                    _ = openingParentheses.popLast()
                }
            }
            previous = character
        }
        return openingParentheses
    }

    private static func isLoggingCall(openingParenthesis: String.Index, in text: String) -> Bool {
        let identifiers = self.callIdentifiers(openingParenthesis: openingParenthesis, in: text)
        guard let callName = identifiers.last else { return false }
        if callName == "log" || callName == "logger" || callName.hasSuffix("Logger") {
            return true
        }
        let loggingMethods: Set = ["debug", "error", "fault", "info", "log", "notice", "trace", "verbose", "warning"]
        guard loggingMethods.contains(callName.lowercased()) else { return false }
        return identifiers.dropLast().contains { identifier in
            identifier == "log" || identifier == "logger" || identifier == "CodexBarLog" ||
                identifier.hasSuffix("Logger")
        }
    }

    private static func isLogCategoryConstructor(openingParenthesis: String.Index, in text: String) -> Bool {
        let identifiers = self.callIdentifiers(openingParenthesis: openingParenthesis, in: text)
        guard let callName = identifiers.last else { return false }
        return callName == "OSLog" || callName == "Logger" || callName == "logger" ||
            callName.hasSuffix("LogCategory") || callName.hasSuffix("LogCategories")
    }

    private static func callIdentifiers(openingParenthesis: String.Index, in text: String) -> [String] {
        let expression = self.callExpression(openingParenthesis: openingParenthesis, in: text)
        var identifiers: [String] = []
        var identifier = ""
        var depth = 0
        for character in expression {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, self.isIdentifierCharacter(character) {
                identifier.append(character)
            } else if depth == 0, !identifier.isEmpty {
                identifiers.append(identifier)
                identifier = ""
            }
        }
        if !identifier.isEmpty {
            identifiers.append(identifier)
        }
        return identifiers
    }

    private static func callExpression(openingParenthesis: String.Index, in text: String) -> Substring {
        var start = openingParenthesis
        while start > text.startIndex {
            let previous = text.index(before: start)
            let character = text[previous]
            if character.isWhitespace || self.isIdentifierCharacter(character) || character == "." {
                start = previous
            } else if character == ")", let matchingOpening = self.matchingOpeningParenthesis(
                for: previous,
                in: text)
            {
                start = matchingOpening
            } else {
                break
            }
        }
        return text[start..<openingParenthesis]
    }

    private static func matchingOpeningParenthesis(
        for closingParenthesis: String.Index,
        in text: String) -> String.Index?
    {
        var openingParentheses: [String.Index] = []
        var previous: Character?
        var isInsideString = false
        for index in text.indices where index <= closingParenthesis {
            let character = text[index]
            if character == "\"", previous != "\\" {
                isInsideString.toggle()
            } else if !isInsideString {
                if character == "(" {
                    openingParentheses.append(index)
                } else if character == ")" {
                    guard let opening = openingParentheses.popLast() else { return nil }
                    if index == closingParenthesis {
                        return opening
                    }
                }
            }
            previous = character
        }
        return nil
    }

    private static func currentArgumentLabel(openingParenthesis: String.Index, in text: String) -> String? {
        let argumentStart = text.index(after: openingParenthesis)
        var currentStart = argumentStart
        var delimiterDepth = 0
        var previous: Character?
        var isInsideString = false
        var index = argumentStart
        while index < text.endIndex {
            let character = text[index]
            if character == "\"", previous != "\\" {
                isInsideString.toggle()
            } else if !isInsideString {
                if character == "(" || character == "[" || character == "{" {
                    delimiterDepth += 1
                } else if character == ")" || character == "]" || character == "}" {
                    delimiterDepth -= 1
                } else if character == ",", delimiterDepth == 0 {
                    currentStart = text.index(after: index)
                }
            }
            previous = character
            index = text.index(after: index)
        }
        let argumentPrefix = text[currentStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard argumentPrefix.hasSuffix(":") else { return nil }
        let label = argumentPrefix.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        return label.allSatisfy(self.isIdentifierCharacter) ? label : nil
    }

    private static func statementContexts(for lines: [String]) -> [StatementContext] {
        var contexts = Array(
            repeating: StatementContext(prefixBeforeLine: ""),
            count: lines.count)
        var statementLines: [Int] = []
        var fragments: [String] = []
        var delimiterDepth = 0

        func finishStatement() {
            guard !fragments.isEmpty else { return }
            var prefix = ""
            for (offset, line) in statementLines.enumerated() {
                contexts[line] = StatementContext(prefixBeforeLine: prefix)
                prefix += fragments[offset] + "\n"
            }
            statementLines.removeAll(keepingCapacity: true)
            fragments.removeAll(keepingCapacity: true)
        }

        for (index, line) in lines.enumerated() {
            let code = self.codeBeforeLineComment(line)
            statementLines.append(index)
            fragments.append(code)
            delimiterDepth += self.statementDelimiterDelta(in: code)
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            let explicitlyContinued = trimmed.hasSuffix("=") || trimmed.hasSuffix("->")
            if delimiterDepth <= 0, !explicitlyContinued {
                finishStatement()
                delimiterDepth = 0
            }
        }
        if !statementLines.isEmpty {
            finishStatement()
        }
        return contexts
    }

    private static func statementDelimiterDelta(in line: String) -> Int {
        var delta = 0
        var previous: Character?
        var isInsideString = false
        for character in line {
            if character == "\"", previous != "\\" {
                isInsideString.toggle()
            } else if !isInsideString {
                if character == "(" || character == "[" {
                    delta += 1
                } else if character == ")" || character == "]" {
                    delta -= 1
                }
            }
            previous = character
        }
        return delta
    }

    private static func providerMarkerReason(in line: String) -> String? {
        guard let comment = self.lineComment(in: line) else { return nil }
        let trimmed = comment.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard trimmed.hasPrefix(self.providerCaseMarker) else { return nil }
        let reason = trimmed.dropFirst(self.providerCaseMarker.count)
            .trimmingCharacters(in: .whitespaces)
        return reason.isEmpty ? nil : reason
    }

    private static func lineComment(in line: String) -> String? {
        var previous: Character?
        var isInsideString = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"", previous != "\\" {
                isInsideString.toggle()
            } else if character == "/", !isInsideString {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "/" {
                    return String(line[line.index(after: next)...])
                }
            }
            previous = character
            index = line.index(after: index)
        }
        return nil
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            let hasLeftBoundary = range.lowerBound == text.startIndex ||
                !self.isIdentifierCharacter(text[text.index(before: range.lowerBound)])
            let hasRightBoundary = range.upperBound == text.endIndex ||
                !self.isIdentifierCharacter(text[range.upperBound])
            if hasLeftBoundary, hasRightBoundary {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func containsSuppressionToken(_ token: String, in text: some StringProtocol) -> Bool {
        guard let first = token.first, let last = token.last else { return false }
        var searchStart = text.startIndex
        while let range = text.range(of: token, range: searchStart..<text.endIndex) {
            let hasLeftBoundary = !self.isIdentifierCharacter(first) || range.lowerBound == text.startIndex ||
                !self.isIdentifierCharacter(text[text.index(before: range.lowerBound)])
            let hasRightBoundary = !self.isIdentifierCharacter(last) || range.upperBound == text.endIndex ||
                !self.isIdentifierCharacter(text[range.upperBound])
            if hasLeftBoundary, hasRightBoundary {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private struct QuotedStringLiteral {
        let value: String
        let range: Range<String.Index>
    }

    private static func quotedStringLiterals(in line: String) -> [QuotedStringLiteral] {
        var literals: [QuotedStringLiteral] = []
        var current = ""
        var literalStart: String.Index?
        var isInsideString = false
        var isEscaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if isInsideString {
                if isEscaped {
                    current.append(character)
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    let end = line.index(after: index)
                    if let literalStart {
                        literals.append(QuotedStringLiteral(value: current, range: literalStart..<end))
                    }
                    current = ""
                    literalStart = nil
                    isInsideString = false
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                literalStart = index
                isInsideString = true
            }
            index = line.index(after: index)
        }
        return literals
    }

    private static func codeBeforeLineComment(_ line: String) -> String {
        var previous: Character?
        var isInsideString = false
        var characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"", previous != "\\" {
                isInsideString.toggle()
            } else if character == "/", !isInsideString, index + 1 < characters.count {
                if characters[index + 1] == "/" {
                    return String(characters[..<index])
                }
                if characters[index + 1] == "*" {
                    // Blank single-line block comments with spaces so punctuation adjacency stays
                    // visible to position heuristics while every character index is preserved.
                    var end = index + 2
                    while end + 1 < characters.count, !(characters[end] == "*" && characters[end + 1] == "/") {
                        end += 1
                    }
                    guard end + 1 < characters.count else {
                        return String(characters[..<index])
                    }
                    for blank in index...(end + 1) {
                        characters[blank] = " "
                    }
                    previous = " "
                    index = end + 2
                    continue
                }
            }
            previous = character
            index += 1
        }
        return String(characters)
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path(percentEncoded: false))
            {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func hash(_ color: ProviderColor, into fingerprint: inout UInt64) {
        for component in [color.red, color.green, color.blue] {
            var bits = component.bitPattern
            for _ in 0..<MemoryLayout<UInt64>.size {
                fingerprint = (fingerprint ^ UInt64(UInt8(truncatingIfNeeded: bits))) &* 1_099_511_628_211
                bits >>= 8
            }
        }
    }

    private static func hash(_ bytes: String.UTF8View, into fingerprint: inout UInt64) {
        for byte in bytes {
            fingerprint = (fingerprint ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
