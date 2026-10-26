import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ProviderBrowsingTests {
    private func store(
        defaults: UserDefaults = InMemoryUserDefaults(),
        config: CodexBarConfig? = nil) -> SettingsStore
    {
        testSettingsStore(suiteName: "ProviderBrowsingTests", userDefaults: defaults, config: config)
    }

    @Test
    func `restore availability follows provider order and alphabetical sorting independently of filtering`() {
        let settings = self.store()
        #expect(!settings.canRestoreDefaultProviderOrder)
        #expect(!settings.restoreDefaultProviderOrder())
        settings.providersEnabledOnly = true
        #expect(!settings.canRestoreDefaultProviderOrder)

        settings.providersSortedAlphabetically = true
        #expect(settings.canRestoreDefaultProviderOrder)
        #expect(settings.restoreDefaultProviderOrder())
        #expect(!settings.canRestoreDefaultProviderOrder)
        #expect(settings.undoProviderOrderChange())
        #expect(settings.canRestoreDefaultProviderOrder)

        settings.providersSortedAlphabetically = false
        let original = settings.configSnapshot.providers.map(\.id)
        settings.setProviderOrder(original.reversed())
        #expect(settings.canRestoreDefaultProviderOrder)
        #expect(settings.restoreDefaultProviderOrder())
        #expect(!settings.canRestoreDefaultProviderOrder)
        #expect(settings.undoProviderOrderChange())
        #expect(settings.canRestoreDefaultProviderOrder)
    }

    @Test
    func `stale undo cannot overwrite an external order or a later mode choice`() {
        let settings = self.store()
        let initial = settings.orderedFirstPartyProviders().map(\.instanceID)
        #expect(settings.moveVisibleProviders(initial, fromOffsets: [0], toOffset: 3))
        settings.providersSortedAlphabetically = true
        #expect(settings.restoreDefaultProviderOrder())
        settings.providersSortedAlphabetically = true
        #expect(settings.undoProviderOrderChange())
        #expect(settings.providersSortedAlphabetically)
        settings.providersSortedAlphabetically = false
        #expect(settings.restoreDefaultProviderOrder())
        settings.setProviderOrder(initial.reversed())
        #expect(!settings.undoProviderOrderChange())
    }

    @Test
    func `native undo rejects a callback for an older action`() throws {
        let settings = self.store()
        #expect(settings.moveVisibleProviders(
            settings.orderedFirstPartyProviders().map(\.instanceID), fromOffsets: [0], toOffset: 3))
        let oldAction = try #require(settings.providerOrderUndo?.id)
        #expect(settings.moveVisibleProviders(
            settings.orderedFirstPartyProviders().map(\.instanceID), fromOffsets: [0], toOffset: 3))
        let latest = settings.configSnapshot.providers.map(\.id)
        #expect(!settings.undoProviderOrderChange(matching: oldAction))
        #expect(settings.configSnapshot.providers.map(\.id) == latest)
        let newAction = try #require(settings.providerOrderUndo?.id)
        #expect(settings.undoProviderOrderChange(matching: newAction))
    }

    @Test
    func `native undo keeps only the latest order action and clears stale menu commands`() {
        let settings = self.store()
        let manager = UndoManager()
        manager.groupsByEvent = false
        let initial = settings.orderedFirstPartyProviders().map(\.instanceID)
        #expect(settings.moveVisibleProviders(initial, fromOffsets: [0], toOffset: 3))
        let afterFirst = settings.configSnapshot.providers.map(\.id)
        manager.beginUndoGrouping()
        settings.registerProviderOrderUndo(in: manager)
        manager.endUndoGrouping()
        #expect(manager.canUndo)
        #expect(settings.moveVisibleProviders(
            settings.orderedFirstPartyProviders().map(\.instanceID), fromOffsets: [0], toOffset: 3))
        manager.beginUndoGrouping()
        settings.registerProviderOrderUndo(in: manager)
        manager.endUndoGrouping()
        manager.undo()
        #expect(settings.configSnapshot.providers.map(\.id) == afterFirst)
        #expect(!manager.canUndo)
        #expect(!settings.canUndoProviderOrderChange)

        #expect(settings.restoreDefaultProviderOrder())
        manager.beginUndoGrouping()
        settings.registerProviderOrderUndo(in: manager)
        manager.endUndoGrouping()
        #expect(settings.undoProviderOrderChange())
        #expect(!manager.canUndo)

        #expect(settings.restoreDefaultProviderOrder())
        manager.beginUndoGrouping()
        settings.registerProviderOrderUndo(in: manager)
        manager.endUndoGrouping()
        settings.setProviderOrder(initial.reversed())
        #expect(!manager.canUndo)
        #expect(!settings.canUndoProviderOrderChange)
    }

    @Test
    func `automatic or filtered views reject reorder`() {
        let settings = self.store()
        let visible = settings.orderedFirstPartyProviders().map(\.instanceID)
        settings.providersSortedAlphabetically = true
        #expect(!settings.moveVisibleProviders(visible, fromOffsets: [0], toOffset: 2))
        settings.providersSortedAlphabetically = false
        settings.providersEnabledOnly = true
        #expect(!settings.moveVisibleProviders(visible, fromOffsets: [0], toOffset: 2))
    }

    @Test
    func `unknown plugin payload survives restoring and undoing order`() throws {
        let config = try CodexBarConfig.decode(from: Data(#"""
        {"version":1,"providers":[
          {"id":"gemini","enabled":false,"apiKey":"synthetic-key"},
          {"id":"retired-plugin","enabled":true,"opaque":{"large":123456789012345678901234567890}},
          {"id":"codex","enabled":true}
        ]}
        """#.utf8))
        let settings = self.store(config: config)
        #expect(settings.restoreDefaultProviderOrder())
        #expect(settings.undoProviderOrderChange())
        let data = try settings.configSnapshot.encodedData()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("123456789012345678901234567890"))
        #expect(json.contains("retired-plugin"))
        #expect(settings.configSnapshot.unavailableProviders.first?.index == 1)
    }

    @Test
    func `enabled filter persists locally without exporting or rewriting provider configuration`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = self.store(defaults: defaults)
        let before = try settings.configSnapshot.encodedData()
        let revision = settings.backgroundWorkSettingsRevision
        #expect(!settings.providersEnabledOnly)
        settings.providersEnabledOnly = true
        settings.providersSortedAlphabetically = true
        #expect(try settings.configSnapshot.encodedData() == before)
        #expect(settings.backgroundWorkSettingsRevision == revision)
        #expect(self.store(defaults: defaults).providersEnabledOnly)
        let portable = try PreferencesDocument(data: settings.exportPreferences().encoded())
        #expect(try portable.value("providersEnabledOnly", as: Bool.self) == nil)
        #expect(try portable.value("providersSortedAlphabetically", as: Bool.self) == true)
        #expect(try portable.value("providerListSortMode", as: String.self) == nil)
    }

    @Test
    func `legacy cloud sorting and portable exports retain the existing Boolean contract`() throws {
        let settings = self.store()
        let configBefore = try settings.configSnapshot.encodedData()
        var preferences = settings.syncedPreferences
        for alphabetical in [true, false, true] {
            preferences.providersSortedAlphabetically = alphabetical
            settings.applySyncedPreferences(preferences)
            #expect(settings.providersSortedAlphabetically == alphabetical)
            let portable = try PreferencesDocument(data: settings.exportPreferences().encoded())
            let target = self.store()
            target.providersSortedAlphabetically = !alphabetical
            try target.importPreferences(portable)
            #expect(target.providersSortedAlphabetically == alphabetical)
        }
        #expect(try settings.configSnapshot.encodedData() == configBefore)
    }
}
