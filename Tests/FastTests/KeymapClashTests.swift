import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct KeymapClashTests {
    /// Keep the stored choices, including explicitly removed defaults.
    private func withDefaults(_ test: (Keymap) throws -> Void) rethrows {
        _ = NSApplication.shared
        let keymap = Keymap.shared
        let saved = Store.settings.object(forKey: "shortcuts")
        defer {
            if let saved { Store.settings.set(saved, forKey: "shortcuts") }
            else { Store.settings.removeObject(forKey: "shortcuts") }
            keymap.adoptStored()
        }
        Store.settings.set([String: String](), forKey: "shortcuts")
        keymap.adoptStored()
        try test(keymap)
    }

    @Test func readingModeCanTakeTheKeyFromEveryContext() throws {
        try withDefaults { keymap in
            let key = Hotkey("r", [.shift, .command])
            guard case .taken(let words, let free) = keymap.clash(key, for: .reader) else {
                Issue.record("The reporter's key must offer Overwrite for all owners")
                return
            }
            #expect(words == "Already used by Reload without the cache, Reveal the selected file and Change a field answer's model")
            #expect(keymap.keys(.hardReload) == key)
            #expect(keymap.keys(.fieldReveal) == key)
            #expect(keymap.keys(.fieldAnswerModel) == key)
            free()
            #expect(keymap.keys(.hardReload) == nil)
            #expect(keymap.keys(.fieldReveal) == nil)
            #expect(keymap.keys(.fieldAnswerModel) == nil)
            #expect(keymap.chosen[Shortcut.Action.hardReload.rawValue] == "")
            #expect(keymap.chosen[Shortcut.Action.fieldAnswerModel.rawValue] == "")
            keymap.set(key, for: .reader)
            let restored = Keymap.resolved(chosen: keymap.chosen)
            #expect(restored[.reader] == key)
            #expect(restored[.hardReload] == nil)
            #expect(restored[.fieldReveal] == nil)
            #expect(restored[.fieldAnswerModel] == nil)
            let reload = Hotkey("r", [.option, .command])
            #expect(keymap.clash(reload, for: .hardReload) == nil)
            keymap.set(reload, for: .hardReload)
            #expect(Keymap.resolved(chosen: keymap.chosen)[.hardReload] == reload)
            // The catalog itself is unchanged.
            #expect(Shortcut.byAction[.reader]?.key == reload)
            #expect(Shortcut.byAction[.hardReload]?.key == key)
        }
    }

    @Test func copyURLNamesAndFreesAllItsOwners() throws {
        try withDefaults { keymap in
            let key = Hotkey("c", [.option, .command])
            guard case .taken(let words, let free) = keymap.clash(key, for: .copyAddress) else {
                Issue.record("Copy URL must offer Inspect an element's key")
                return
            }
            #expect(words == "Already used by Inspect an element and Copy the one-time code")
            free()
            keymap.set(key, for: .copyAddress)
            #expect(keymap.keys(.copyAddress) == key)
            #expect(keymap.keys(.inspectElement) == nil)
            #expect(keymap.keys(.fieldCode) == nil)
            #expect(keymap.keys(.reader) == Hotkey("r", [.option, .command]))
        }
    }

    @Test func importsKeepTheirExistingMultipleOwnerRefusal() {
        withDefaults { keymap in
            let key = Hotkey("r", [.shift, .command])
            guard case .refused(let words) = keymap.clash(key, for: nil, takeSeveral: false) else {
                Issue.record("An import without confirmation must not take several owners' keys")
                return
            }
            #expect(words.contains("Reload without the cache"))
            #expect(words.contains("Change a field answer's model"))
            #expect(keymap.keys(.hardReload) == key)
            #expect(keymap.keys(.fieldAnswerModel) == key)
            guard case .taken = keymap.clash(Hotkey("w", [.shift, .command]), for: nil, takeSeveral: false) else {
                Issue.record("An import must still offer a single default owner's key")
                return
            }
        }
    }

    @Test func overwriteFreesActionsAndQuickActionsTogether() throws {
        try withDefaults { keymap in
            let id = "clash-test-" + UUID().uuidString
            let key = Hotkey("k", [.control, .option, .command])
            let quicks = QuickActions.shared
            let quick = QuickAction(id: id, name: "Clash fixture", url: "https://example.com/", alias: "",
                                    shortcut: key.stored, custom: true)
            try #require(quicks.put(quick) == nil)
            defer { quicks.remove(id) }
            keymap.set(key, for: .hardReload)
            guard case .taken(let words, let free) = keymap.clash(key, for: .reader) else {
                Issue.record("An action and a quick action must be overwritten together")
                return
            }
            #expect(words == "Already used by Reload without the cache and Clash fixture")
            free()
            #expect(keymap.keys(.hardReload) == nil)
            #expect(quicks.action(id)?.shortcut == "")
            keymap.set(key, for: .reader)
            #expect(keymap.keys(.reader) == key)
        }
    }

    @Test func protectedKeysRemainRefused() {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        defer { app.mainMenu = previousMenu }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "c")
        app.mainMenu = menu
        withDefaults { keymap in
            for key in [Hotkey("q", .command), Hotkey("c", .command), Hotkey("r", [])] {
                guard case .refused = keymap.clash(key, for: .reader) else {
                    Issue.record("Protected key \(key.text) offered Overwrite")
                    continue
                }
            }
            #expect(keymap.keys(.reader) == Shortcut.byAction[.reader]?.key)
        }
    }

    @Test func snippetRefusalTakesPriorityOverAnOverwritableOwner() {
        withDefaults { keymap in
            let key = Hotkey("r", [.shift, .command])
            let snippets = MailSnippets.shared
            let snippet = snippets.add(name: "clash-" + UUID().uuidString, body: "Fixture", hotkey: key.stored)
            defer { snippets.remove(snippet.id) }
            guard case .refused(let words) = keymap.clash(key, for: .reader) else {
                Issue.record("A snippet must stay protected even when browser actions share its key")
                return
            }
            #expect(words.contains(snippet.name))
            #expect(keymap.keys(.hardReload) == key)
            #expect(keymap.keys(.fieldAnswerModel) == key)
            #expect(snippets.snippet(snippet.id)?.hotkey == key.stored)
        }
    }

    /// ⌘H is Hide Yab's, so macOS keeps it, until App Shortcuts gives Hide
    /// Yab other keys: then an action may take it, and loses it again when
    /// Hide Yab has ⌘H back (register 2989).
    @Test func commandHIsFreeOnceAppShortcutsMoveHideYab() {
        withDefaults { keymap in
            let saved = NSApp.mainMenu
            let menu = NSMenu(), app = NSMenuItem()
            app.submenu = NSMenu()
            let hide = NSMenuItem(title: "Hide Yab", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            app.submenu?.addItem(hide)
            menu.addItem(app)
            NSApp.mainMenu = menu
            defer {
                NSApp.mainMenu = saved
                keymap.take(system: [:])
            }
            let commandH = Hotkey("h", .command)
            keymap.take(system: [:])
            guard case .refused(let words) = keymap.clash(commandH, for: .duplicate) else {
                Issue.record("⌘H is Hide Yab's while nobody moved it")
                return
            }
            #expect(words == "macOS keeps this one.")

            // App Shortcuts gives Hide Yab ⌃⌘H, and AppKit draws it so.
            hide.keyEquivalentModifierMask = [.control, .command]
            keymap.take(system: ["Hide Yab": "^@h"])
            if case .refused(let words) = keymap.clash(commandH, for: .duplicate) {
                Issue.record("⌘H refused after Hide Yab moved: \(words)")
            }
            // A choice of ⌘H is kept, not dropped as macOS's. (Not through
            // `set`: it reads this Mac's own App Shortcuts again.)
            let chose = [Shortcut.Action.duplicate.rawValue: commandH.stored]
            #expect(Keymap.valid(commandH, for: .duplicate))
            #expect(Keymap.resolved(chosen: chose)[.duplicate] == commandH)

            // Given ⌘H back, Hide Yab has it again and the action does not.
            hide.keyEquivalentModifierMask = .command
            keymap.take(system: ["Hide Yab": "@h"])
            #expect(!Keymap.valid(commandH, for: .duplicate))
            #expect(Keymap.resolved(chosen: chose)[.duplicate] != commandH)
        }
    }
}
