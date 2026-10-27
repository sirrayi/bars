import Foundation
import Testing
@testable import BarsCore

struct ProviderAccentColorTests {
    @Test
    func `hex string parses with and without the leading hash`() throws {
        let withHash = try #require(ProviderColor(hexString: "#60BA7E"))
        let withoutHash = try #require(ProviderColor(hexString: "60BA7E"))

        #expect(withHash == withoutHash)
        #expect(withHash == ProviderColor(hex: 0x60BA7E))
    }

    @Test
    func `hex string tolerates lowercase and surrounding whitespace`() throws {
        let color = try #require(ProviderColor(hexString: "  #60ba7e \n"))

        #expect(color == ProviderColor(hex: 0x60BA7E))
    }

    @Test
    func `malformed hex strings return nil instead of a color`() {
        #expect(ProviderColor(hexString: "") == nil)
        #expect(ProviderColor(hexString: "#FFF") == nil)
        #expect(ProviderColor(hexString: "#60BA7EFF") == nil)
        #expect(ProviderColor(hexString: "#60BA7Z") == nil)
        #expect(ProviderColor(hexString: "not a color") == nil)
        // Swift's integer parser accepts a sign, so a six-character signed value must still fail.
        #expect(ProviderColor(hexString: "+60BA7") == nil)
    }

    @Test
    func `hex string round trips through the canonical uppercase form`() throws {
        let color = try #require(ProviderColor(hexString: "#60ba7e"))

        #expect(color.hexString == "#60BA7E")
        #expect(ProviderColor(hexString: color.hexString) == color)
    }

    @Test
    func `hex string clamps components outside the unit range`() {
        let color = ProviderColor(red: -1, green: 0.5, blue: 2)

        #expect(color.hexString == "#0080FF")
    }

    @Test
    func `accent color survives a config round trip`() throws {
        let config = BarsConfig(providers: [
            ProviderConfig(id: .opencode, enabled: true, accentColor: "#60BA7E"),
        ])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BarsConfig.self, from: data)

        #expect(decoded.providerConfig(for: .opencode)?.accentColor == "#60BA7E")
    }

    @Test
    func `a config without an accent color decodes as no override`() throws {
        let json = #"{"version":1,"providers":[{"id":"opencode","enabled":true}]}"#
        let data = try #require(json.data(using: .utf8))

        let decoded = try JSONDecoder().decode(BarsConfig.self, from: data)

        #expect(decoded.providerConfig(for: .opencode)?.accentColor == nil)
        #expect(ProviderAccentColors.overrides(in: decoded).isEmpty)
    }

    @Test
    func `the mirrored payload round trips through its string encoding`() {
        let overrides: [ProviderInstanceID: ProviderColor] = [
            .opencode: ProviderColor(hex: 0x60BA7E),
            .claude: ProviderColor(hex: 0xD97757),
        ]

        let encoded = ProviderAccentColors.encode(overrides)

        #expect(encoded["opencode"] == "#60BA7E")
        #expect(encoded["claude"] == "#D97757")
        #expect(ProviderAccentColors.decode(encoded) == overrides)
    }

    @Test
    func `the mirrored payload drops unknown providers and bad colors`() {
        let decoded = ProviderAccentColors.decode([
            "opencode": "#60BA7E",
            "claude": "not-a-color",
            "": "#FFFFFF",
        ])

        #expect(decoded == [.opencode: ProviderColor(hex: 0x60BA7E)])
    }

    @Test
    func `sync carries the accent override to another Mac`() throws {
        let local = ProviderConfig(id: .opencode, enabled: true, accentColor: "#60BA7E")

        let payload = ProviderIntentPayload(config: local)
        let applied = try payload.applying(
            to: ProviderConfig(id: .opencode),
            secretFields: [:],
            canEnable: { _, _ in true })

        #expect(payload.accentColor == "#60BA7E")
        #expect(applied.accentColor == "#60BA7E")
    }

    @Test
    func `sync clears the accent override when the sending Mac cleared it`() throws {
        let payload = ProviderIntentPayload(config: ProviderConfig(id: .opencode, enabled: true))

        let applied = try payload.applying(
            to: ProviderConfig(id: .opencode, accentColor: "#60BA7E"),
            secretFields: [:],
            canEnable: { _, _ in true })

        // A Mac that knows the field reports an empty string, which means "the user cleared it".
        #expect(payload.accentColor?.isEmpty == true)
        #expect(applied.accentColor == nil)
    }

    @Test
    func `a client that predates accent colors cannot erase an override`() throws {
        // A payload from an older Mac carries no accentColor key at all.
        let legacy = #"""
        {"schemaVersion":1,"provider":"opencode","enabled":true}
        """#
        let data = try #require(legacy.data(using: .utf8))
        let payload = try JSONDecoder().decode(ProviderIntentPayload.self, from: data)

        let applied = try payload.applying(
            to: ProviderConfig(id: .opencode, accentColor: "#60BA7E"),
            secretFields: [:],
            canEnable: { _, _ in true })

        #expect(payload.accentColor == nil)
        #expect(applied.accentColor == "#60BA7E")
    }
}
