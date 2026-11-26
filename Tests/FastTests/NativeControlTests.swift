import AppKit
import Foundation
import Testing
@testable import Fast
@testable import MailCore

@Suite(.serialized)
struct NativeControlTests {
    @Test func jsonKeepsBooleansDistinctFromNumbers() throws {
        #expect(try NativeValue.read(true) == .bool(true))
        #expect(try NativeValue.read(1) == .number(1))
        #expect(try NativeValue.read(["a": 1, "b": false]) == .object(["a": .number(1), "b": .bool(false)]))
        #expect(NativeValue.object(["a": .number(1), "b": .bool(false)]).fingerprint == NativeValue.object(["b": .bool(false), "a": .number(1)]).fingerprint)
    }

    @MainActor @Test func schemasRejectTyposWrongTypesAndPermissionChanges() throws {
        let theme = try #require(NativeActions.descriptors.first { $0["id"] as? String == "settings.set.theme" })
        try NativeActions.validate(["value": .string("dark")], descriptor: theme)
        #expect(throws: NativeFailure.self) { try NativeActions.validate(["value": .bool(true)], descriptor: theme) }
        #expect(throws: NativeFailure.self) { try NativeActions.validate(["value": .string("night")], descriptor: theme) }
        #expect(throws: NativeFailure.self) { try NativeActions.validate(["value": .string("dark"), "bypass": .bool(true)], descriptor: theme) }
        #expect(throws: NativeFailure.self) { try NativeActions.validate([:], descriptor: theme) }
        #expect(!NativeActions.descriptors.contains { ($0["id"] as? String ?? "").contains("agents-asking") })
        #expect(Set(NativeActions.descriptors.compactMap { $0["id"] as? String }).count == NativeActions.descriptors.count)
        #expect(NativeActions.descriptors.allSatisfy { $0["version"] as? Int == NativeActions.version })
    }

    @MainActor @Test func integerAndNumberRangesAreEnforced() throws {
        let fonts = try #require(NativeActions.descriptors.first { $0["id"] as? String == "pages.set_fonts" })
        #expect(throws: NativeFailure.self) { try NativeActions.validate(["size": .number(100)], descriptor: fonts) }
        #expect(throws: NativeFailure.self) { try NativeActions.validate(["size": .number(12.5)], descriptor: fonts) }
        let zoom = try #require(NativeActions.descriptors.first { $0["id"] as? String == "site.set_zoom" })
        #expect(throws: NativeFailure.self) { try NativeActions.validate(["value": .number(0.1)], descriptor: zoom) }
        #expect(throws: NativeFailure.self) { try NativeActions.validate(["value": .number(.infinity)], descriptor: zoom) }
    }

    @MainActor @Test func onlyInteractiveRootTasksCanWrite() {
        let session = Agents.Session(id: "native-test", cli: "external", name: "Test", prompt: "", state: .attached)
        #expect(NativeControl.writable(session))
        #expect(!NativeControl.writable(session, nobody: true))
        session.textOnly = true; #expect(!NativeControl.writable(session))
        session.textOnly = false
        session.profile = "context_explorer"; #expect(!NativeControl.writable(session))
        session.profile = "default"; session.parent = "parent"; #expect(!NativeControl.writable(session))
        session.parent = nil; session.sealed = true; #expect(!NativeControl.writable(session))
        session.sealed = false; session.remembering = true; #expect(!NativeControl.writable(session))
        session.remembering = false; session.state = .stopped; #expect(!NativeControl.writable(session))
    }

    @MainActor @Test func retryIsBoundToTaskAndExactPayload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = NativeChanges(file: folder.appendingPathComponent("journal.json"))
        let receipt = try ledger.prepare(session: "a", request: "once", fingerprint: "payload", action: "theme", target: "app", resource: "theme", before: .string("light"))
        #expect(try ledger.existing(session: "a", request: "once", fingerprint: "payload")?.id == receipt.id)
        #expect(try ledger.existing(session: "b", request: "once", fingerprint: "payload") == nil)
        #expect(throws: NativeFailure.self) { try ledger.existing(session: "a", request: "once", fingerprint: "different") }
        #expect(ledger.receipt(receipt.id, session: "b") == nil)
    }

    @MainActor @Test func undoDetectsManualChangeEvenWhenValueReturns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = NativeChanges(file: folder.appendingPathComponent("journal.json"))
        let receipt = try ledger.prepare(session: "a", request: "theme", fingerprint: "p", action: "theme", target: "app", resource: "theme", before: .string("light"))
        let value = NativeValue.string("dark")
        try ledger.update(receipt.id, status: "verified", result: ["status": "verified"], after: value, version: ledger.version("theme", value))
        let saved = try #require(ledger.receipt(receipt.id, session: "a"))
        #expect(ledger.canUndo(saved, current: value))
        ledger.changed("other"); #expect(ledger.canUndo(saved, current: value))
        ledger.changed("theme"); ledger.changed("theme")
        #expect(!ledger.canUndo(saved, current: value))
    }

    @MainActor @Test func restartNeverRetriesAnUnknownEffectOrOverwritesLaterEdits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("journal.json")
        let ledger = NativeChanges(file: file)
        let receipt = try ledger.prepare(session: "a", request: "once", fingerprint: "p", action: "theme", target: "app", resource: "theme", before: .string("light"))
        let recovered = NativeChanges(file: file)
        #expect(recovered.receipt(receipt.id, session: "a")?.status == "unknown_outcome")
        try ledger.update(receipt.id, status: "verified", result: ["status": "verified"], after: .string("dark"), version: ledger.version("theme", .string("dark")))
        let afterRestart = NativeChanges(file: file)
        #expect(!afterRestart.canUndo(try #require(afterRestart.receipt(receipt.id, session: "a")), current: .string("dark")))
    }

    @MainActor @Test func nativeConfirmationCannotBecomeAPageApproval() {
        let permit = AgentPermit(kind: .native(label: "Disconnect Gmail", operation: "op-1"), session: "a", detail: "Remove local mail")
        #expect(permit.isNative && permit.weighty)
        #expect(permit.key == "native:op-1")
        #expect(permit.ruleLabel == nil)
    }

    @Test func commandsActButPlanningAndQuestionsDoNot() {
        for text in ["turn on dark mode", "add gmail", "connect my work mail", "dark mode", "undo", "Can you turn on dark mode?",
                     "set the search engine to Kagi", "turn off peek", "make the background blue", "show the full URL",
                     "change the search engine to Kagi", "turn off the warning before quitting",
                     "turn off the small window", "set linear.app links to open in Work", "make figma.com open in Design",
                     "keep web.whatsapp.com awake", "make youtube open in webkit", "set the reading font to Georgia"] {
            #expect(TaskWords.nativeRequest(text), "\(text)")
            #expect(TaskWords.strength(text) == .strong)
        }
        for text in ["Think through how to add mail", "How do I turn on dark mode?", "What happens if I delete a space?", "espresso grinder"] {
            #expect(!TaskWords.nativeRequest(text), "\(text)")
        }
    }

    @Test func oauthCallbacksRejectForeignStateDuplicatesAndWrongPaths() {
        #expect(MailOAuthCallback.read("GET /oauth?state=ours&code=fake HTTP/1.1", state: "ours")?.code == "fake")
        #expect(MailOAuthCallback.read("GET /oauth?state=foreign&code=fake HTTP/1.1", state: "ours") == nil)
        #expect(MailOAuthCallback.read("GET /oauth-extra?state=ours&code=fake HTTP/1.1", state: "ours") == nil)
        #expect(MailOAuthCallback.read("GET /oauth?state=ours&state=ours&code=fake HTTP/1.1", state: "ours") == nil)
        #expect(MailOAuthCallback.read("GET /oauth?state=ours&code=a&code=b HTTP/1.1", state: "ours") == nil)
        #expect(MailOAuthCallback.read("GET /oauth?state=ours&code=a&error=x&error=y HTTP/1.1", state: "ours") == nil)
        #expect(MailOAuthCallback.read("POST /oauth?state=ours&code=fake HTTP/1.1", state: "ours") == nil)
        #expect(MailOAuthCallback.read("GET /oauth?state=ours&error=access_denied HTTP/1.1", state: "ours")?.error == "access_denied")
        #expect(!MailClient.accepts(MailClient.calendarScope))
        #expect(MailClient.accepts(MailClient.scope))
    }

    @MainActor private func call(_ control: NativeControl, _ verb: String, _ browser: Browser, _ session: Agents.Session,
                                _ values: [String: Any] = [:]) -> [String: Any] {
        var request = values; request["session"] = session.id
        var result: [String: Any] = [:]
        control.handle("agent-native-" + verb, request: request, browser: browser) { result = $0 }
        return result
    }

    @MainActor private func fixture(_ test: (NativeControl, Browser, Agents.Session) throws -> Void) rethrows {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID()
        let browser = Browser(windowID: id)
        _ = browser.open(URL(string: "about:blank#native-test")!, foreground: true)
        let session = Agents.shared.attach(name: "Native test")
        defer {
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            Agents.shared.detach(session.id)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        try test(NativeControl(file: folder.appendingPathComponent("operations.json")), browser, session)
    }

    @MainActor @Test func transparencyChangesOnlyTheTargetSpaceAndUndoes() throws {
        let spaces = Store.file("spaces.json"), data = try? Data(contentsOf: spaces)
        defer { if let data { try? data.write(to: spaces) } else { try? FileManager.default.removeItem(at: spaces) } }
        try fixture { control, browser, session in
            let held = SpacePaint(browser.prefs)
            defer { held.wear(browser.prefs) }
            let paint = SpacePaint(swatch: .custom, color: NSColor(hex: "8DB6E6")!, grain: 0.4,
                                   colors: ["EEA2C4"], transparency: 0.2)
            let id = browser.addSpace(named: "Transparency test", ownSignIns: false, paint: paint, show: false)
            let request: [String: Any] = ["action": "settings.set.transparency", "target": ["kind": "space", "id": id.uuidString],
                                          "arguments": ["value": 0.9], "requestId": "transparency"]
            let applied = call(control, "apply", browser, session, request)
            #expect(applied["status"] as? String == "verified")
            let changed = try #require(browser.spaces.first { $0.id == id }?.paint)
            #expect(changed.transparency == 0.9)
            #expect(changed.color == paint.color && changed.colors == paint.colors && changed.grain == paint.grain)
            #expect(SpacePaint(browser.prefs) == held)
            let operation = try #require(applied["operationId"] as? String)
            #expect(call(control, "undo", browser, session, ["changeId": operation])["undone"] as? Bool == true)
            #expect(browser.spaces.first { $0.id == id }?.paint == paint)
        }
    }

    @MainActor @Test func actualThemePersistsRetriesOnceAndUndoes() throws {
        let previous = Store.settings.object(forKey: "look")
        defer { Store.settings.set(previous, forKey: "look") }
        try fixture { control, browser, session in
            browser.prefs.look = .light
            let context = call(control, "context", browser, session)
            let theme = try #require((context["settings"] as? [[String: Any]])?.first { $0["id"] as? String == "theme" })
            let request: [String: Any] = ["action": "settings.set.theme", "target": ["kind": "application", "id": "app"],
                                          "arguments": ["value": "dark"], "expectedVersion": theme["resourceVersion"]!, "requestId": "theme-once"]
            let applied = call(control, "apply", browser, session, request)
            #expect(applied["status"] as? String == "verified")
            #expect(browser.prefs.look == .dark)
            #expect(Store.settings.string(forKey: "look") == "dark")
            #expect(call(control, "apply", browser, session, request)["operationId"] as? String == applied["operationId"] as? String)
            #expect(control.changes.receipts.count == 1)
            let undone = call(control, "undo", browser, session, ["changeId": applied["operationId"]!])
            #expect(undone["undone"] as? Bool == true)
            #expect(browser.prefs.look == .light)
            #expect(Store.settings.string(forKey: "look") == "light")
            #expect(call(control, "undo", browser, session, ["changeId": applied["operationId"]!])["status"] as? String == "conflict")
        }
    }

    @MainActor @Test func manualThemeRoundTripInvalidatesUndoAndStaleRequests() throws {
        let previous = Store.settings.object(forKey: "look")
        defer { Store.settings.set(previous, forKey: "look") }
        try fixture { control, browser, session in
            browser.prefs.look = .light
            let preview: [String: Any] = ["action": "settings.set.theme", "target": ["kind": "application", "id": "app"], "arguments": ["value": "dark"]]
            let version = try #require(call(control, "context", browser, session, preview)["resourceVersion"] as? String)
            var request = preview; request["requestId"] = "dark"; request["expectedVersion"] = version
            let applied = call(control, "apply", browser, session, request)
            #expect(applied["status"] as? String == "verified")
            browser.prefs.look = .light; browser.prefs.look = .dark
            #expect(call(control, "undo", browser, session, ["changeId": applied["operationId"]!])["status"] as? String == "conflict")
            request["requestId"] = "stale"
            #expect(call(control, "apply", browser, session, request)["status"] as? String == "conflict")
            #expect(control.changes.receipts.count == 1)
            #expect(browser.prefs.look == .dark)
        }
    }

    /// A Settings row an agent can't change is answered with steps by hand
    /// (feedback #84): each one is in the registry, the user's, an
    /// operation, or ui_only by decision. Shortcuts are Shortcuts' own.
    @MainActor @Test func everySettingsRowIsClassified() {
        let loose = SettingsItem.all.filter { !$0.id.hasPrefix("key:") && NativeActions.classification($0) == "ui_only" && !NativeActions.uiOnly.contains($0.id) }
        #expect(loose.isEmpty, "Classify these rows in NativeActions: \(loose.map(\.id))")
        let native = Set(NativeSetting.all.map(\.id))
        #expect(NativeActions.uiOnly.isDisjoint(with: native) && NativeActions.uiOnly.isDisjoint(with: NativeActions.controlled))
    }

    @MainActor @Test func newSettingsWriteWhatTheirRowsWrite() throws {
        let held = (ReaderStyle.shared.prefs, Store.settings.object(forKey: PeekClick.key))
        defer { ReaderStyle.shared.prefs = held.0; Store.settings.set(held.1, forKey: PeekClick.key) }
        @MainActor func setting(_ id: String) throws -> NativeSetting { try #require(NativeSetting.all.first { $0.id == id }) }
        try fixture { _, browser, _ in
            try setting("reader-size").write(browser.prefs, .number(22))
            #expect(ReaderLook.sizes[ReaderStyle.shared.prefs.look.size] == 22)
            #expect(throws: NativeFailure.self) { try setting("reader-size").write(browser.prefs, .number(21)) }
            try setting("reader-font").write(browser.prefs, .string("georgia"))
            #expect(ReaderStyle.shared.prefs.look.font == .georgia)
            try setting("reader-theme").write(browser.prefs, .string("paper"))
            #expect(try setting("reader-theme").read(browser.prefs) == .string("paper"))
            try setting("peek-click").write(browser.prefs, .string("option"))
            #expect(Store.settings.string(forKey: PeekClick.key) == "option")
        }
    }

    @MainActor @Test func siteDarkAndAwakeChangeTheirSiteAndUndo() throws {
        let awake = AwakeSites.shared.sites, dark = Store.settings.object(forKey: DarkPages.choiceKey("dark-test.example"))
        defer { AwakeSites.shared.restore(awake); Store.settings.set(dark, forKey: DarkPages.choiceKey("dark-test.example")) }
        try fixture { control, browser, session in
            Store.settings.removeObject(forKey: DarkPages.choiceKey("dark-test.example"))
            @MainActor func apply(_ action: String, _ arguments: [String: Any], _ id: String) -> [String: Any] {
                call(control, "apply", browser, session, ["action": action, "target": ["kind": "application", "id": "app"],
                                                          "arguments": arguments, "requestId": id])
            }
            let light = apply("site.set_dark", ["site": "https://www.Dark-Test.example/page", "value": "light"], "light")
            #expect(light["status"] as? String == "verified")
            #expect(DarkPages.choice("dark-test.example") == "off")
            #expect(call(control, "undo", browser, session, ["changeId": light["operationId"]!])["undone"] as? Bool == true)
            #expect(DarkPages.choice("dark-test.example") == nil)

            AwakeSites.shared.restore(["discord.com"])
            let off = apply("site.keep_awake", ["site": "ptb.discord.com", "value": false], "sleep")
            #expect(off["status"] as? String == "verified")
            #expect(AwakeSites.shared.sites.isEmpty)
            #expect(call(control, "undo", browser, session, ["changeId": off["operationId"]!])["undone"] as? Bool == true)
            #expect(AwakeSites.shared.sites == ["discord.com"])
            #expect(apply("site.keep_awake", ["site": "notion.so", "value": true], "awake")["status"] as? String == "verified")
            #expect(AwakeSites.shared.sites == ["discord.com", "notion.so"])
        }
    }

    @MainActor @Test func linkRoutesSetRemoveDefaultAndUndo() throws {
        let spaces = Store.file("spaces.json"), data = try? Data(contentsOf: spaces)
        let held = (LinkRoutes.shared.routes, LinkRoutes.shared.defaultSpace)
        defer {
            LinkRoutes.shared.restore(held.0, defaultSpace: held.1)
            if let data { try? data.write(to: spaces) } else { try? FileManager.default.removeItem(at: spaces) }
        }
        try fixture { control, browser, session in
            LinkRoutes.shared.restore([], defaultSpace: nil)
            let work = browser.addSpace(named: "Links \(UUID().uuidString.prefix(6))", ownSignIns: false, show: false)
            @MainActor func apply(_ action: String, _ arguments: [String: Any], _ id: String) -> [String: Any] {
                call(control, "apply", browser, session, ["action": action, "target": ["kind": "application", "id": "app"],
                                                          "arguments": arguments, "requestId": id])
            }
            let set = apply("links.set_route", ["site": "https://www.Linear.app/", "space": work.uuidString, "skipSmallWindow": true], "route")
            #expect(set["status"] as? String == "verified")
            #expect(LinkRoutes.shared.routes == [LinkRoute(site: "linear.app", space: work, opensInMain: true)])
            let rules = try #require((call(control, "context", browser, session)["linkRoutes"] as? [String: Any])?["rules"] as? [[String: Any]])
            #expect(rules.first?["site"] as? String == "linear.app" && rules.first?["skipSmallWindow"] as? Bool == true)

            // Omitted, the window choice stays; a word becomes a pattern.
            #expect(apply("links.set_route", ["site": "linear.app", "space": "recent"], "recent")["status"] as? String == "verified")
            #expect(LinkRoutes.shared.route(site: "linear.app") == LinkRoute(site: "linear.app", space: LinkRoutes.recentSpaceID, opensInMain: true))
            #expect(apply("links.set_route", ["site": "figma", "space": work.uuidString], "word")["status"] as? String == "verified")
            #expect(LinkRoutes.shared.route(site: "*figma*")?.space == work)

            #expect(apply("links.set_route", ["site": "two words", "space": work.uuidString], "bad-site")["code"] as? String == "invalid_arguments")
            #expect(apply("links.set_route", ["site": "notion.so", "space": UUID().uuidString], "bad-space")["code"] as? String == "not_found")
            #expect(apply("links.remove_route", ["site": "notion.so"], "missing")["code"] as? String == "not_found")

            let fallback = apply("links.set_default_space", ["space": work.uuidString], "default")
            #expect(LinkRoutes.shared.defaultSpace == work)
            #expect(call(control, "undo", browser, session, ["changeId": fallback["operationId"]!])["undone"] as? Bool == true)
            #expect(LinkRoutes.shared.defaultSpace == nil)

            let removed = apply("links.remove_route", ["site": "linear.app"], "remove")
            #expect(removed["status"] as? String == "verified")
            #expect(LinkRoutes.shared.route(site: "linear.app") == nil)
            #expect(call(control, "undo", browser, session, ["changeId": removed["operationId"]!])["undone"] as? Bool == true)
            #expect(LinkRoutes.shared.routes.map(\.site) == ["linear.app", "*figma*"])
            #expect(LinkRoutes.shared.route(site: "linear.app")?.opensInMain == true)
        }
    }

    @MainActor @Test func createdSpaceIsIdempotentAndCanBeUndoneWhileEmpty() throws {
        let spaces = Store.file("spaces.json"), data = try? Data(contentsOf: spaces)
        let enabled = Store.settings.object(forKey: "spaces")
        defer {
            Store.settings.set(enabled, forKey: "spaces")
            if let data { try? data.write(to: spaces) } else { try? FileManager.default.removeItem(at: spaces) }
        }
        try fixture { control, browser, session in
            let before = Set(browser.spaces.map(\.id))
            let request: [String: Any] = ["action": "space.create", "target": ["kind": "application", "id": "app"],
                                          "arguments": ["name": "Native \(UUID().uuidString)"], "requestId": "create"]
            let applied = call(control, "apply", browser, session, request)
            #expect(applied["status"] as? String == "verified")
            #expect(browser.spaces.count == before.count + 1)
            #expect(call(control, "apply", browser, session, request)["operationId"] as? String == applied["operationId"] as? String)
            #expect(browser.spaces.count == before.count + 1)
            #expect(call(control, "undo", browser, session, ["changeId": applied["operationId"]!])["undone"] as? Bool == true)
            #expect(Set(browser.spaces.map(\.id)) == before)
        }
    }

    @MainActor @Test func confirmationIsOwnerBoundRechecksChangesAndCancels() throws {
        let spaces = Store.file("spaces.json"), data = try? Data(contentsOf: spaces)
        defer { if let data { try? data.write(to: spaces) } else { try? FileManager.default.removeItem(at: spaces) } }
        try fixture { control, browser, session in
            let space = browser.addSpace(named: "Native temporary", ownSignIns: false, show: false)
            let request: [String: Any] = ["action": "space.delete", "target": ["kind": "space", "id": space.uuidString], "arguments": [:], "requestId": "delete"]
            let pending = call(control, "apply", browser, session, request)
            let operation = try #require(pending["operationId"] as? String)
            #expect(pending["status"] as? String == "needs_user")
            #expect(browser.active?.permit?.isNative == true)
            control.decide(operation, session: "other-task", yes: true)
            #expect(browser.spaces.contains { $0.id == space })
            browser.renameSpace(space, to: "Changed by user")
            control.decide(operation, session: session.id, yes: true)
            #expect(control.changes.receipt(operation, session: session.id)?.status == "conflict")
            #expect(browser.spaces.contains { $0.id == space })
            browser.active?.permit = nil
            if let anchor = browser.active { Agents.shared.handBack(anchor) }
            var second = request; second["requestId"] = "delete-again"
            let cancelled = call(control, "apply", browser, session, second)
            let cancelID = try #require(cancelled["operationId"] as? String)
            control.stop(session.id, browser: browser)
            control.decide(cancelID, session: session.id, yes: true)
            #expect(control.changes.receipt(cancelID, session: session.id)?.status == "cancelled")
            #expect(browser.spaces.contains { $0.id == space })
        }
    }

    @MainActor @Test func closedOriginWindowCannotRedirectToAnotherWindow() throws {
        try fixture { control, browser, session in
            session.nativeWindowID = UUID()
            let request: [String: Any] = ["action": "settings.set.theme", "target": ["kind": "application", "id": "app"], "arguments": ["value": "dark"], "requestId": "wrong-window"]
            #expect(call(control, "apply", browser, session, request)["status"] as? String == "conflict")
            #expect(control.changes.receipts.isEmpty)
        }
    }

    @MainActor @Test func privateTabsAreAbsentFromNativeContextAndTargets() throws {
        try fixture { control, browser, session in
            browser.newShyTab()
            let privateID = try #require(browser.active?.id)
            #expect(browser.active?.shy == true)
            let context = call(control, "context", browser, session)
            #expect(context["activeTab"] == nil)
            #expect(!(context["tabs"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == privateID.uuidString })
            let request: [String: Any] = ["action": "tabs.rename", "target": ["kind": "tab", "id": privateID.uuidString], "arguments": ["name": "private leak"], "requestId": "private"]
            #expect(call(control, "apply", browser, session, request)["code"] as? String == "not_found")
            #expect(control.changes.receipts.isEmpty)
        }
    }

    @MainActor @Test func websiteMetadataContainsOriginWithoutCredentialsOrTokens() throws {
        try fixture { control, browser, session in
            let tab = try #require(browser.active)
            tab.restore(url: URL(string: "https://user:secret@example.test/private-path?token=supersecret#otp=123456")!, title: "Opaque page")
            let context = call(control, "context", browser, session)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)
            #expect(json.contains("example.test"))
            #expect((context["activeTab"] as? [String: Any])?["url"] as? String == "https://example.test")
            for word in ["secret", "private-path", "otp=123456", "token="] { #expect(!json.contains(word), "\(word)") }
        }
    }

    @MainActor @Test func reorderingAndGroupingUseRealRowsAndRestoreThem() throws {
        let previous = Store.settings.object(forKey: "agents.asking")
        defer { Store.settings.set(previous, forKey: "agents.asking") }
        try fixture { control, browser, session in
            browser.prefs.agentsAsking = .bypass
            let first = try #require(browser.active), second = Tab(), third = Tab()
            for (index, tab) in [first, second, third].enumerated() {
                tab.restore(url: URL(string: "https://example.test/\(index)")!, title: "Native page \(index)")
                browser.prepare(tab)
            }
            browser.lay([first, second, third])
            let original = browser.tabs.map(\.id)
            let target = ["kind": "space", "id": browser.spaceID.uuidString]
            let reorder: [String: Any] = ["action": "tabs.reorder", "target": target,
                                          "arguments": ["tabs": original.reversed().map(\.uuidString)], "requestId": "reorder"]
            let applied = call(control, "apply", browser, session, reorder)
            #expect(applied["status"] as? String == "verified")
            #expect(browser.tabs.map(\.id) == Array(original.reversed()))
            #expect(call(control, "undo", browser, session, ["changeId": applied["operationId"]!])["undone"] as? Bool == true)
            #expect(browser.tabs.map(\.id) == original)
            let grouped = call(control, "apply", browser, session, ["action": "tabs.group", "target": target,
                                                                   "arguments": ["tabs": [first.id.uuidString, third.id.uuidString], "name": "Native folder"], "requestId": "group"])
            #expect(grouped["status"] as? String == "verified")
            #expect(first.kept && third.kept && first.nest === third.nest)
            #expect(first.nest?.name == "Native folder")
            #expect(call(control, "undo", browser, session, ["changeId": grouped["operationId"]!])["undone"] as? Bool == true)
            #expect(browser.tabs.map(\.id) == original)
            #expect(!first.kept && !third.kept && first.nest == nil && third.nest == nil)
        }
    }

    @MainActor @Test func liveFoldersAreListedChangedUndoneAndStopOnlyAfterAYes() throws {
        let empties = Store.file("empty-folders.json"), data = try? Data(contentsOf: empties)
        let enabled = Store.settings.object(forKey: LiveFolderFeature.key)
        let previous = Folders.shared.browser
        defer {
            Store.settings.set(enabled, forKey: LiveFolderFeature.key)
            if let data { try? data.write(to: empties) } else { try? FileManager.default.removeItem(at: empties) }
            Folders.shared.browser = previous
        }
        try fixture { control, browser, session in
            // Off, so nothing here reads GitHub.
            browser.prefs.usesLiveFolders = false
            Folders.shared.browser = browser
            let nest = try #require(Folders.shared.makeEmpty(named: "Pull Requests", live: Live(source: "github.pulls", host: "github.com", show: LiveGitHub.shownAtFirst)))
            defer { Folders.shared.removeEmpty(nest) }
            let target = ["kind": "liveFolder", "id": nest.id.uuidString]

            let context = call(control, "context", browser, session)
            let live = try #require(context["liveFolders"] as? [String: Any])
            let folders = try #require(live["folders"] as? [[String: Any]])
            #expect(live["enabled"] as? Bool == false)
            #expect(folders.contains { $0["id"] as? String == nest.id.uuidString && $0["source"] as? String == "github.pulls" })
            #expect((live["sources"] as? [[String: Any]])?.contains { $0["id"] as? String == "linear" } == true)

            let list = try #require(LiveGitHub.lists.first?.id)
            let set = call(control, "apply", browser, session, ["action": "live.set", "target": target,
                                                                "arguments": ["name": "Reviews", "show": [list], "hidden": ["acme/old"]], "requestId": "live-set"])
            #expect(set["status"] as? String == "verified")
            #expect(nest.name == "Reviews" && nest.live?.show == [list] && nest.live?.hidden == ["acme/old"])
            #expect(call(control, "apply", browser, session, ["action": "live.set", "target": target, "arguments": ["show": ["nope"]], "requestId": "live-bad"])["status"] as? String != "verified")
            #expect(call(control, "apply", browser, session, ["action": "live.set", "target": target, "arguments": ["days": 30], "requestId": "live-days"])["status"] as? String != "verified")
            #expect(call(control, "undo", browser, session, ["changeId": set["operationId"]!])["undone"] as? Bool == true)
            #expect(nest.name == "Pull Requests" && nest.live?.show == LiveGitHub.shownAtFirst && nest.live?.hidden == [])

            #expect(call(control, "apply", browser, session, ["action": "live.update", "target": target, "arguments": [:], "requestId": "live-update"])["code"] as? String == "disabled")
            let stop = call(control, "apply", browser, session, ["action": "live.stop", "target": target, "arguments": [:], "requestId": "live-stop"])
            #expect(stop["status"] as? String == "needs_user")
            #expect(nest.live != nil)
            control.decide(stop["operationId"] as? String ?? "", session: session.id, yes: true)
            #expect(nest.live == nil)

            let on = call(control, "apply", browser, session, ["action": "settings.set.live-folders", "target": ["kind": "application", "id": "app"],
                                                               "arguments": ["value": true], "requestId": "live-on"])
            #expect(on["status"] as? String == "verified" && browser.prefs.usesLiveFolders)
            #expect(call(control, "undo", browser, session, ["changeId": on["operationId"]!])["undone"] as? Bool == true)
            #expect(!browser.prefs.usesLiveFolders)
        }
    }

    @MainActor @Test func corruptJournalIsPreservedAndFailsBeforeAnyEffect() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("operations.json"), corrupt = Data("broken ledger".utf8)
        try corrupt.write(to: file)
        let ledger = NativeChanges(file: file)
        #expect(throws: NativeFailure.self) { try ledger.prepare(session: "a", request: "r", fingerprint: "p", action: "theme", target: "app", resource: "theme", before: .null) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @MainActor @Test func movingTabsUndoesAndDetectsManualChangesInParkedRow() throws {
        let spaces = Store.file("spaces.json"), data = try? Data(contentsOf: spaces)
        let asking = Store.settings.object(forKey: "agents.asking"), enabled = Store.settings.object(forKey: "spaces")
        defer {
            Store.settings.set(asking, forKey: "agents.asking"); Store.settings.set(enabled, forKey: "spaces")
            if let data { try? data.write(to: spaces) } else { try? FileManager.default.removeItem(at: spaces) }
        }
        try fixture { control, browser, session in
            browser.prefs.agentsAsking = .bypass; browser.prefs.usesSpaces = true
            let first = try #require(browser.active), second = Tab()
            for (index, tab) in [first, second].enumerated() {
                tab.restore(url: URL(string: "https://example.test/native-\(index)")!, title: "Native move \(index)")
                browser.prepare(tab)
            }
            browser.lay([first, second])
            let destination = browser.addSpace(named: "Native move target", ownSignIns: false, show: false)
            defer { browser.deleteSpace(destination) }
            let request: [String: Any] = ["action": "tabs.move", "target": ["kind": "space", "id": destination.uuidString.lowercased()],
                                          "arguments": ["tabs": [first.id.uuidString]], "requestId": "move"]
            let moved = call(control, "apply", browser, session, request)
            #expect(moved["status"] as? String == "verified")
            #expect(!browser.tabs.contains { $0 === first })
            #expect(browser.parked[destination]?.tabs.contains { $0 === first } == true)
            #expect(call(control, "undo", browser, session, ["changeId": moved["operationId"]!])["undone"] as? Bool == true)
            #expect(browser.tabs.map(\.id) == [first.id, second.id])
            var again = request; again["requestId"] = "move-again"
            let next = call(control, "apply", browser, session, again)
            #expect(next["status"] as? String == "verified")
            first.name = "Manual edit"; first.name = nil
            #expect(call(control, "undo", browser, session, ["changeId": next["operationId"]!])["status"] as? String == "conflict")
            #expect(browser.parked[destination]?.tabs.contains { $0 === first } == true)
        }
    }

    @MainActor @Test func differentSignInStoreReopensTabsAndRejectsBlankTransfers() throws {
        let spaces = Store.file("spaces.json"), data = try? Data(contentsOf: spaces)
        let enabled = Store.settings.object(forKey: "spaces")
        defer {
            Store.settings.set(enabled, forKey: "spaces")
            if let data { try? data.write(to: spaces) } else { try? FileManager.default.removeItem(at: spaces) }
        }
        try fixture { control, browser, session in
            browser.prefs.usesSpaces = true
            let first = try #require(browser.active)
            first.restore(url: URL(string: "https://example.test/native-account")!, title: "Account fixture")
            let destination = browser.addSpace(named: "Native separate sign-ins", ownSignIns: true, show: false)
            defer { browser.deleteSpace(destination) }
            let request: [String: Any] = ["action": "tabs.move", "target": ["kind": "space", "id": destination.uuidString],
                                          "arguments": ["tabs": [first.id.uuidString]], "requestId": "separate"]
            let pending = call(control, "apply", browser, session, request)
            #expect(pending["status"] as? String == "needs_user")
            let operation = try #require(pending["operationId"] as? String)
            if let anchor = browser.active { anchor.permit = nil; Agents.shared.handBack(anchor) }
            control.decide(operation, session: session.id, yes: true)
            #expect(control.changes.receipt(operation, session: session.id)?.status == "verified")
            let reopened = try #require(browser.parked[destination]?.tabs.first)
            #expect(reopened.id != first.id)
            #expect(reopened.store === Spaces.store(for: destination))
            let undone = call(control, "undo", browser, session, ["changeId": operation])
            #expect(undone["undone"] as? Bool == true, "\(undone)")
            let returned = try #require(browser.tabs.first)
            #expect(returned.store === Spaces.store(for: browser.spaceID))
            let blank = browser.blankTab()
            browser.lay(browser.tabs + [blank])
            browser.select(blank)
            var transfer = request; transfer["requestId"] = "blank"; transfer["arguments"] = ["tabs": [blank.id.uuidString]]
            let blocked = call(control, "apply", browser, session, transfer)
            let blockedID = try #require(blocked["operationId"] as? String)
            if let anchor = browser.active { anchor.permit = nil; Agents.shared.handBack(anchor) }
            control.decide(blockedID, session: session.id, yes: true)
            #expect(control.changes.receipt(blockedID, session: session.id)?.status == "failed")
            #expect(browser.tabs.contains { $0 === blank })
            #expect(browser.parked[destination]?.tabs.contains { $0 === blank } != true)
        }
    }

    /// Feedback #109: an agent asked to ungroup two folders had no action to
    /// take a tab out of a folder or remove one. The column's Move to
    /// Folder, Move Out of Folder and Remove Folder, Keep Tabs, each undone.
    @MainActor @Test func foldersTakeTabsInAndOutAndUngroupKeepingThemOpen() throws {
        let previous = Store.settings.object(forKey: "agents.asking")
        defer { Store.settings.set(previous, forKey: "agents.asking") }
        try fixture { control, browser, session in
            browser.prefs.agentsAsking = .bypass
            let first = try #require(browser.active), second = Tab(), third = Tab(), fourth = Tab()
            for (index, tab) in [first, second, third, fourth].enumerated() {
                tab.restore(url: URL(string: "https://example.test/folder/\(index)")!, title: "Folder page \(index)")
                browser.prepare(tab)
            }
            let outer = Nest(name: "Outer"), inner = Nest(name: "Inner")
            inner.parent = outer
            first.kept = true; first.nest = outer
            second.kept = true; second.nest = inner
            third.kept = true; third.nest = inner
            browser.lay([first, second, third, fourth])
            let original = browser.tabs.map(\.id)
            let space = ["kind": "space", "id": browser.spaceID.uuidString]
            @MainActor func apply(_ action: String, _ target: [String: String], _ arguments: [String: Any] = [:]) -> [String: Any] {
                call(control, "apply", browser, session, ["action": action, "target": target, "arguments": arguments, "requestId": UUID().uuidString])
            }
            @MainActor func undo(_ result: [String: Any]) -> Bool {
                call(control, "undo", browser, session, ["changeId": result["operationId"] ?? ""])["undone"] as? Bool == true
            }

            let listed = call(control, "actions", browser, session, ["query": "folder"])["actions"] as? [[String: Any]] ?? []
            for id in ["tabs.move_to_folder", "tabs.move_out_of_folder", "folder.ungroup"] {
                #expect(listed.contains { $0["id"] as? String == id && $0["undo"] as? Bool == true }, "\(id)")
            }
            let folders = call(control, "context", browser, session)["folders"] as? [[String: Any]] ?? []
            #expect(folders.contains { $0["id"] as? String == inner.id.uuidString && $0["parentId"] as? String == outer.id.uuidString && $0["tabs"] as? Int == 2 })
            #expect(folders.contains { $0["id"] as? String == outer.id.uuidString && $0["tabs"] as? Int == 3 && $0["ownTabs"] as? Int == 1 })

            // Out of a folder in a folder, to the top of the kept, still open.
            let out = apply("tabs.move_out_of_folder", space, ["tabs": [second.id.uuidString]])
            #expect(out["status"] as? String == "verified", "\(out)")
            #expect(second.nest == nil && second.kept && browser.tabs.contains { $0 === second })
            #expect(inner.parent === outer && third.nest === inner)
            #expect(undo(out))
            #expect(second.nest === inner && browser.tabs.map(\.id) == original)

            // One step out: into the folder its folder is in.
            let step = apply("tabs.move_out_of_folder", space, ["tabs": [second.id.uuidString], "oneStep": true])
            #expect(step["status"] as? String == "verified", "\(step)")
            #expect(second.nest === outer && second.kept)
            #expect(undo(step))
            #expect(second.nest === inner && browser.tabs.map(\.id) == original)

            // A tab not in any folder is refused, nothing changed.
            let loose = apply("tabs.move_out_of_folder", space, ["tabs": [fourth.id.uuidString]])
            #expect(loose["status"] as? String == "failed")
            #expect(browser.tabs.map(\.id) == original)

            // Into a folder: one of today's tabs becomes kept, in it.
            let into = apply("tabs.move_to_folder", ["kind": "folder", "id": inner.id.uuidString], ["tabs": [fourth.id.uuidString]])
            #expect(into["status"] as? String == "verified", "\(into)")
            #expect(fourth.kept && fourth.nest === inner)
            #expect(undo(into))
            #expect(!fourth.kept && fourth.nest == nil && browser.tabs.map(\.id) == original)

            // Ungroup the outer folder: its tab and the folder in it stay,
            // at the top of the kept; every tab still open.
            let ungrouped = apply("folder.ungroup", ["kind": "folder", "id": outer.id.uuidString])
            #expect(ungrouped["status"] as? String == "verified", "\(ungrouped)")
            #expect(first.nest == nil && first.kept && inner.parent == nil && second.nest === inner && third.nest === inner)
            #expect(!browser.nests.contains { $0 === outer })
            #expect(browser.tabs.map(\.id) == original)
            #expect(undo(ungrouped))
            #expect(inner.parent === outer && first.nest === outer && browser.nests.contains { $0 === outer })

            // Both folders ungrouped, as the feedback asked: no folder left,
            // no tab closed.
            #expect(apply("folder.ungroup", ["kind": "folder", "id": inner.id.uuidString])["status"] as? String == "verified")
            #expect(second.nest === outer && third.nest === outer)
            #expect(apply("folder.ungroup", ["kind": "folder", "id": outer.id.uuidString])["status"] as? String == "verified")
            #expect([first, second, third].allSatisfy { $0.nest == nil && $0.kept })
            #expect(browser.nests.isEmpty || !browser.nests.contains { $0 === outer || $0 === inner })
            #expect(Set(browser.tabs.map(\.id)) == Set(original))

            let missing = apply("folder.ungroup", ["kind": "folder", "id": UUID().uuidString])
            #expect(missing["code"] as? String == "not_found")
        }
    }

    @MainActor @Test func closingTheUsersTabsKeepsPinsUnlessNamedAndUndoPutsEveryOneBack() throws {
        let previous = Store.settings.object(forKey: "agents.asking")
        defer { Store.settings.set(previous, forKey: "agents.asking") }
        try fixture { control, browser, session in
            browser.prefs.agentsAsking = .bypass
            let first = try #require(browser.active)
            let pinned = first, kept = Tab(), video = Tab(), article = Tab(), again = Tab(), copy = Tab()
            let pages = [(pinned, "https://www.youtube.com/"), (kept, "https://www.youtube.com/watch?v=kept"),
                         (video, "https://www.youtube.com/watch?v=one"), (article, "https://example.test/article"),
                         (again, "https://www.youtube.com/watch?v=two"), (copy, "https://example.test/article#part")]
            for (tab, address) in pages {
                tab.restore(url: URL(string: address)!, title: address)
                if tab !== first { browser.prepare(tab) }
            }
            let folder = Nest(name: "Watch later")
            pinned.pin = "Y"
            kept.kept = true; kept.nest = folder
            kept.name = "Kept video"
            browser.lay([pinned, kept, video, article, again, copy])
            browser.select(article)
            article.touch(at: Date().addingTimeInterval(-9 * 86_400))
            let row = browser.tabs.map { $0.address?.absoluteString ?? "" }
            let space = ["kind": "space", "id": browser.spaceID.uuidString]
            @MainActor func close(_ tabs: [Tab], pinned: Bool? = nil) -> [String: Any] {
                var arguments: [String: Any] = ["tabs": tabs.map(\.id.uuidString)]
                if let pinned { arguments["includePinned"] = pinned }
                return call(control, "apply", browser, session, ["action": "tabs.close", "target": space, "arguments": arguments, "requestId": UUID().uuidString])
            }
            @MainActor func undo(_ result: [String: Any]) -> [String: Any] {
                call(control, "undo", browser, session, ["changeId": result["operationId"] ?? ""])
            }

            // Listed, undoable, and the context names duplicates and when each was last used.
            let listed = call(control, "actions", browser, session, ["query": "close"])["actions"] as? [[String: Any]] ?? []
            #expect(listed.contains { $0["id"] as? String == "tabs.close" && $0["undo"] as? Bool == true })
            let context = call(control, "context", browser, session, ["limit": 50])["tabs"] as? [[String: Any]] ?? []
            let byID = Dictionary(context.map { ($0["id"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
            let copyOf = byID[copy.id.uuidString]?["duplicateOf"] as? String, firstOf = byID[article.id.uuidString]?["duplicateOf"] as? String
            #expect(copyOf == article.id.uuidString)
            #expect(firstOf == "")
            let used = byID[article.id.uuidString]?["lastUsed"] as? String ?? ""
            let idle = (try? Date(used, strategy: .iso8601)).map { Date().timeIntervalSince($0) } ?? 0
            #expect(idle > 7 * 86_400)

            // A pinned or kept tab only when named: refused whole, nothing closed.
            for refused in [close([pinned, video]), close([video, kept], pinned: false)] {
                #expect(refused["status"] as? String == "failed", "\(refused)")
                #expect(browser.tabs.map { $0.address?.absoluteString ?? "" } == row)
            }

            // The loose YouTube tabs: gone, one line's worth, and back where they stood.
            let closed = close([video, again])
            #expect(closed["status"] as? String == "verified", "\(closed)")
            #expect(closed["closed"] as? Double == 2)
            #expect(!browser.tabs.contains { $0 === video || $0 === again })
            #expect(browser.tabs.count == 4)
            let opened = browser.open(URL(string: "https://example.test/new")!, foreground: false, atEnd: true)
            let back = undo(closed)
            #expect(back["undone"] as? Bool == true, "\(back)")
            #expect(browser.tabs.filter { $0 !== opened }.map { $0.address?.absoluteString ?? "" } == row)
            #expect(browser.tabs.contains { $0 === opened })
            #expect(browser.active === article)
            #expect(undo(closed)["status"] as? String == "conflict")
            browser.close(opened)

            // #1433: named, the pin and the kept tab are put down as ⌘W puts
            // them, asleep, pinned and in their folder; only the loose one goes.
            let pin = browser.tabs[0], keptHere = browser.tabs[1], loose = browser.tabs[2]
            let all = close([pin, keptHere, loose], pinned: true)
            #expect(all["status"] as? String == "verified", "\(all)")
            #expect(all["closed"] as? Double == 1 && all["putDown"] as? Double == 2, "\(all)")
            #expect(browser.tabs.count == 5)
            #expect(browser.tabs.first === pin && pin.pin == "Y" && !pin.kept && pin.asleep)
            #expect(browser.tabs[1] === keptHere && keptHere.kept && keptHere.nest === folder && keptHere.name == "Kept video" && keptHere.asleep)
            #expect(!browser.tabs.contains { $0 === loose })
            #expect(undo(all)["undone"] as? Bool == true)
            #expect(browser.tabs.map { $0.address?.absoluteString ?? "" } == row)
            #expect(browser.tabs[0] === pin && browser.tabs[1] === keptHere)
            #expect(browser.tabs[2].pin == nil && !browser.tabs[2].kept)

            // Only pins put down: nothing closed, nothing to undo, no corner notice.
            browser.toaster.dismiss()
            let rested = close([pin], pinned: true)
            #expect(rested["status"] as? String == "verified", "\(rested)")
            #expect(rested["closed"] as? Double == 0 && (rested["undo"] as? [String: Any])?["available"] as? Bool == false, "\(rested)")
            #expect(browser.tabs.first === pin && pin.pin == "Y" && pin.asleep)
            #expect(browser.tabs.map { $0.address?.absoluteString ?? "" } == row)
            #expect(!browser.toaster.shown)
        }
    }

    @MainActor @Test func closingTabsNeverAsksAndUndoBringsThemBack() throws {
        let previous = Store.settings.object(forKey: "agents.asking")
        defer { Store.settings.set(previous, forKey: "agents.asking") }
        try fixture { control, browser, session in
            let front = try #require(browser.active)
            front.restore(url: URL(string: "https://example.test/front")!, title: "Front")
            var many: [Tab] = []
            for index in 0..<34 {
                let tab = Tab()
                tab.restore(url: URL(string: "https://www.youtube.com/watch?v=\(index)")!, title: "Video \(index)")
                browser.prepare(tab)
                many.append(tab)
            }
            browser.lay([front] + many)
            browser.select(front)
            let space = ["kind": "space", "id": browser.spaceID.uuidString]
            for asking in [AgentAsking.ask, .auto, .bypass] {
                browser.prefs.agentsAsking = asking
                let done = call(control, "apply", browser, session, ["action": "tabs.close", "target": space,
                                                                    "arguments": ["tabs": browser.tabs.filter { $0 !== front }.map(\.id.uuidString)], "requestId": UUID().uuidString])
                #expect(done["status"] as? String == "verified", "\(asking): \(done)")
                #expect(front.permit == nil)
                #expect(browser.tabs.count == 1)
                #expect(call(control, "undo", browser, session, ["changeId": done["operationId"] ?? ""])["undone"] as? Bool == true)
                #expect(browser.tabs.count == 35)
            }
            // Over the limit is refused whole, nothing closed.
            let extra = Array(repeating: UUID().uuidString, count: NativeActions.closeLimit + 1)
            let refused = call(control, "apply", browser, session, ["action": "tabs.close", "target": space,
                                                                  "arguments": ["tabs": extra], "requestId": UUID().uuidString])
            #expect(refused["status"] as? String == "failed", "\(refused)")
            #expect(browser.tabs.count == 35)
        }
    }

    /// The agent's view of a split of three: every tab names all three, in
    /// the split's order, and `splitPartnerId` stays the one it always was.
    @MainActor @Test func contextNamesEveryTabOfASplit() throws {
        try fixture { control, browser, session in
            let first = try #require(browser.active)
            let tabs = [first, Tab(), Tab(), Tab()]
            for (at, tab) in tabs.enumerated() {
                tab.restore(url: URL(string: "https://example.test/\(at)")!, title: "\(at)")
                if at > 0 { browser.prepare(tab) }
            }
            browser.lay(tabs)
            browser.pairs = [Pair(first: tabs[0].id, second: tabs[1].id, more: [tabs[2].id])]
            let context = call(control, "context", browser, session, ["limit": 50])["tabs"] as? [[String: Any]] ?? []
            let byID = Dictionary(context.map { ($0["id"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
            let split = tabs.prefix(3).map(\.id.uuidString)
            for tab in tabs.prefix(3) {
                #expect(byID[tab.id.uuidString]?["splitTabIds"] as? [String] == split)
            }
            #expect(byID[tabs[0].id.uuidString]?["splitPartnerId"] as? String == tabs[1].id.uuidString)
            #expect(byID[tabs[3].id.uuidString]?["splitTabIds"] as? [String] == [])
            #expect(byID[tabs[3].id.uuidString]?["splitPartnerId"] as? String == "")
        }
    }
}
