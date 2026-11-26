import AppKit
import WebKit

@MainActor private var omniboxFixtureTabs: [UUID] = []

// The bench's words for the field, ⌘T's and ⌘L's: opened the way the keys
// open it, typed into through its own editor, keys pressed through the app,
// and read back whole, so a script can walk every case of it and say what
// the window did.
//
//     ./bench box state                what the field and the tabs are now
//     ./bench box t | l | plus         ⌘T, ⌘L, the new-tab button
//     ./bench box type TEXT            typed into the field, as keys would
//     ./bench box key down|return|cmd+return|escape|tab|delete|cmd+k|…
//
// Only on a test run: it takes the window's keyboard.
extension Bench {
    func fieldCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "box only works on a --test run, it types into your window"]); return }
        let act = request["act"] as? String ?? "state"
        let window = BrowserWindows.shared.window(for: browser) ?? Links.window
        let wait = (request["wait"] as? Double) ?? 0.25

        func later(_ then: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: then)
        }
        /// The field's own editor, when it has the cursor, or a field of a
        /// row being written (PlaceEdit).
        func editor() -> NSTextView? {
            guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
                  (editor.delegate as? NSTextField)?.delegate is AddressField.Coordinator || browser.query.acting != nil
                    || (editor.delegate as? NSTextField)?.delegate is EditLine.Coordinator
                    || browser.query.edit?.passwordEditor != nil else { return nil }
            return editor
        }

        switch act {
        case "page-action-fixture":
            // An isolated local-page action for the small window's real
            // omnibox rows. The probe supplies stand-in agent executables.
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            Hints.shared.extra[tab.id] = Skills.Action(title: "Check this fixture page", pattern: "*",
                prompt: "Report the title of this fixture page.", skill: "")
            answer(["id": tab.id.uuidString, "url": tab.address?.absoluteString ?? ""])
            return
        case "instant-links":
            if request["inspect"] as? Bool == true { answer(["events": InstantLinksSearch.diagnostics]); return }
            browser.prefs.instantLinks = request["enabled"] as? Bool ?? true
            Store.settings.set(request["template"] as? String, forKey: "instant.fixtureTemplate")
            browser.prefs.searchSuggest = false
            var state: [String: Any] = ["enabled": browser.prefs.instantLinks]
            if #available(macOS 15.4, *) { state["activeCarriesExtensions"] = browser.active?.carriesExtensions ?? false }
            answer(state)
            return
        case "windows":
            answer(["windows": BrowserWindows.shared.openWindows().map { entry in
                ["title": entry.title,
                 "key": BrowserWindows.shared.window(for: entry.browser)?.isKeyWindow == true,
                 "tabs": entry.browser.tabs.map { ["id": String($0.id.uuidString.prefix(8)), "url": ($0.pending ?? $0.address)?.absoluteString ?? "",
                                                   "pin": $0.pin != nil, "kept": $0.kept] as [String: Any] },
                 "active": entry.browser.active.map { String($0.id.uuidString.prefix(8)) } ?? "",
                 // Its space and where it stands on the screen, for a launch's
                 // restore to be checked against.
                 "space": entry.browser.space.name,
                 // A Blank Window, and the sign-ins its tabs are made with:
                 // the same store as its space's (BlankWindow.swift).
                 "blank": entry.browser.blank,
                 "sameStore": entry.browser.active.map { $0.store === Spaces.store(for: entry.browser.spaceID) } ?? true,
                 "frame": BrowserWindows.shared.window(for: entry.browser).map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height].map(Double.init) } ?? []] as [String: Any]
            }])
            return
        case "reopen-window":
            // Window › Reopen Closed Window, as the menu's row does it.
            BrowserWindows.shared.reopenClosedWindow()
            later { answer(["windows": BrowserWindows.shared.openWindows().count]) }
            return
        case "focus-window":
            guard let number = request["number"] as? Int,
                  BrowserWindows.shared.openWindows().indices.contains(number - 1) else {
                answer(["error": "focus-window needs an open window number"])
                return
            }
            let target = BrowserWindows.shared.openWindows()[number - 1].browser
            BrowserWindows.shared.show(target)
            later { answer(Bench.fieldState(target)) }
            return
        case "blur":
            NSApp.deactivate()
            later { answer(["active": NSApp.isActive]) }
            return
        case "appearance":
            // Read the same answers Liquid Glass and the traffic lights
            // ask for, including windows behind the active one.
            typealias Glass = @convention(c) (AnyObject, Selector) -> Bool
            typealias Buttons = @convention(c) (AnyObject, Selector, UInt) -> Bool
            let glass = NSSelectorFromString("_hasActiveAppearance")
            let buttons = NSSelectorFromString("_hasActiveAppearanceForStandardWindowButton:")
            answer(["active": NSApp.isActive, "windows": NSApp.windows.compactMap { window -> [String: Any]? in
                guard window === Links.window || window is BrowserWindow,
                      window.responds(to: glass), window.responds(to: buttons) else { return nil }
                return ["class": String(describing: type(of: window)), "number": window.windowNumber,
                        "key": window.isKeyWindow, "main": window.isMainWindow,
                        "visible": window.isVisible,
                        "glass": unsafeBitCast(window.method(for: glass), to: Glass.self)(window, glass),
                        "buttons": unsafeBitCast(window.method(for: buttons), to: Buttons.self)(window, buttons, 0)]
            }])
            return
        case "prepare":
            // A local page keeps the field down until the measured opening.
            // Return without reading fieldState: that would warm up the very
            // history and action getters whose first use we want to measure.
            for tab in browser.tabs where omniboxFixtureTabs.contains(tab.id) { browser.close(tab) }
            omniboxFixtureTabs = []
            browser.history.seedBench(request["history"] as? Int ?? 0)
            let page = URL(string: "data:text/html,%3Cbody%3EOmnibox%20bench%3C/body%3E")!
            let base = browser.open(page, foreground: true)
            omniboxFixtureTabs.append(base.id)
            for _ in 0..<max(0, min(request["tabs"] as? Int ?? 0, 100)) {
                omniboxFixtureTabs.append(browser.open(page, foreground: false, atEnd: true).id)
            }
            let clips = max(0, min(request["clips"] as? Int ?? 0, 2_000))
            Clips.shared.seedOmniboxBench(clips)
            let traces = browser.history.everything().filter { $0.key.hasPrefix("omnibox-bench.invalid/") }
            let tabs = omniboxFixtureTabs.count
            if request["diary"] as? Int == 0 {
                answer(["ready": true, "history": traces.count,
                        "tabs": tabs, "clips": clips])
                return
            }
            Diary.shared.seedBench(traces) { ready in
                answer(["ready": ready, "history": traces.count,
                        "tabs": tabs, "clips": clips])
            }
            return
        case "clip-preview-fixture":
            guard let path = request["path"] as? String, FileManager.default.fileExists(atPath: path) else {
                answer(["error": "clip-preview-fixture needs a synthetic picture's path"])
                return
            }
            Clips.shared.seedPreviewBench(file: URL(fileURLWithPath: path))
        case "clip-preview-pick":
            browser.query.spot = max(0, min(2, request["index"] as? Int ?? 0))
        case "preview-fixture":
            // Deterministic clipboard search results, without asking a model
            // or touching the system clipboard. Render the real request rows.
            var found = Candidates()
            found.clips = Array(Clips.shared.items.prefix(4))
            let reading = RequestReader.Reading(kind: "find_clip", found: found)
            let requests = FieldActions.build(reading, browser.typed, browser) ?? []
            let query = browser.query
            let rest = query.offers.filter { if case .request = $0.kind { false } else { true } }
            FieldRequest.shown[ObjectIdentifier(browser)] = requests
            query.offers = requests.enumerated().map { index, item in
                Suggestion(key: item.title, title: item.site, url: nil, kind: .request(index))
            } + rest
            query.unpick()
            query.lead = requests.count < query.offers.count ? requests.count : 0
        case "search-suggest":
            if let on = request["on"] as? Bool { browser.prefs.searchSuggest = on }
            if let raw = request["engine"] as? String, let engine = Engine(rawValue: raw) { browser.prefs.engine = engine }
        case "private": browser.newShyTab()
        // ⌘N as File › New Window does it, for a probe that isn't the
        // active app, whose key equivalents never reach the menu.
        case "new-window": browser.newWindow()
        // File › Blank Window, the same way.
        case "blank-window": browser.newBlankWindow()
        case "move-space":
            // The tab in front to a space by name, its own if none, as Move
            // to Space does it: out of a Blank Window into a window of yours.
            let name = (request["space"] as? String)?.lowercased()
            let target = browser.spaces.first { $0.name.lowercased() == name }?.id ?? browser.spaceID
            if let tab = browser.active { _ = browser.moveTabs([tab], to: target) }
        case "t": browser.newTab()
        case "plus": browser.newTab()
        case "l": browser.edit()
        case "type":
            // Into the field's editor, as the keyboard's letters go in, so the
            // field's own delegate hears each one.
            let text = request["text"] as? String ?? ""
            let go = {
                guard let editor = editor() else { answer(["error": "the field doesn't have the cursor"]); return }
                for letter in text { editor.insertText(String(letter), replacementRange: editor.selectedRange()) }
                later { answer(Bench.fieldState(browser)) }
            }
            // A field that has just come up takes the cursor a beat later.
            if editor() == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: go) } else { go() }
            return
        case "key":
            guard let keys = request["keys"] as? String, let (flags, name, typed) = Bench.chord(keys) else {
                answer(["error": "box key needs keys: down, return, cmd+return, escape, tab, delete, cmd+k"])
                return
            }
            // Into the app's queue rather than handed straight to it, so the
            // key is the app's current event while it is handled, as a real
            // one is (⌥↩ is told from ↩ by reading it).
            let arrows: [String: (UInt16, Int)] = ["down": (125, NSDownArrowFunctionKey), "up": (126, NSUpArrowFunctionKey),
                                                   "left": (123, NSLeftArrowFunctionKey), "right": (124, NSRightArrowFunctionKey),
                                                   "←": (123, NSLeftArrowFunctionKey), "→": (124, NSRightArrowFunctionKey),
                                                   "↓": (125, NSDownArrowFunctionKey), "↑": (126, NSUpArrowFunctionKey)]
            let plain: [String: String] = ["esc": "\u{1b}", "⇥": "\t", "↩": "\r", "⌫": "\u{7f}", "space": " "]
            let code: UInt16
            let chars: String
            if let (key, char) = arrows[name] {
                code = key
                chars = String(UnicodeScalar(char)!)
            } else {
                code = KeyLayout.code(for: name) ?? Bench.keyCode(for: Character(name.isEmpty ? " " : String(name.prefix(1))))
                chars = typed ?? plain[name] ?? name
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        case "reset":
            // A row of plain tabs at these addresses, the first in front, and
            // nothing else: what a test starts from.
            let old = browser.tabs
            let made = (request["urls"] as? [String] ?? []).compactMap(URL.init(string:)).map {
                browser.open($0, foreground: false, atEnd: true)
            }
            for tab in old { browser.close(tab) }
            if let first = made.first { browser.select(first) }
            browser.editing = false
        case "close":
            // ⌘W on the tab in front.
            if let tab = browser.active { browser.close(tab) }
        case "board":
            // Something on the clipboard as an app would put it: words, and
            // any other kinds named with them (a password manager's
            // concealed mark), then the history looks at once.
            let item = NSPasteboardItem()
            item.setString(request["text"] as? String ?? "", forType: .string)
            for type in request["types"] as? [String] ?? [] { item.setString("1", forType: NSPasteboard.PasteboardType(type)) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
            Clips.shared.look()
        case "files-folder", "field-filter":
            // What the list is narrowed to, at the field's end, pressed.
            browser.chooseFilter()
        case "quiet-menus":
            // What ⌘K last listed, forgotten.
            Browser.shownActions = []
        case "run":
            // An action of the chosen row by its title, as picked from ⌘K.
            let title = request["title"] as? String ?? ""
            if let action = browser.fieldActions.first(where: { $0.title == title }) { action.run() }
        case "open-place":
            // A place straight from its key or menu (Browser.openPlace).
            if let place = FieldPlace(rawValue: request["place"] as? String ?? "") { browser.openPlace(place) }
        case "seed-places":
            // Downloads, logins, a card, an address and pages visited, in
            // a test world only: its keychain items and files are its own.
            guard Store.testing else { answer(["error": "seed-places only works in a test world"]); return }
            Bench.seedPlaces(browser, many: request["many"] as? Int ?? 0)
        case "password-source":
            // Settings › Passwords: Use Yab's passwords, the managers
            // connected (an unlock password is a test value only), the last
            // unlock marked, the sheet, and who fills and saves now.
            if let yab = request["yab"] as? Bool { browser.prefs.usesYabPasswords = yab }
            let connections = PasswordManagers.Connections.shared
            var saved = true
            for id in request["connect"] as? [String] ?? [] {
                let password = request["password"] as? String
                let mode: PasswordManagers.Mode = password == nil ? .you : .yab
                // As Connect on its page does: a manager new to Yab opens its own page.
                saved = (request["sign_in"] as? Bool == true
                    ? connections.connectAndSignIn(id, mode: mode, password: password)
                    : connections.connect(id, mode: mode, password: password)) && saved
            }
            if request["refresh"] as? Bool == true { ManagerExtensions.shared.refresh() }
            if let id = request["open"] as? String { PasswordManagers.open(id, in: browser) }
            for id in request["disconnect"] as? [String] ?? [] { connections.disconnect(id) }
            if let id = request["failed"] as? String { connections.unlocked(id, ok: false) }
            // The finger, played: Touch ID's answer for Yab's unlock for the
            // person, and a new session (the Mac locked and back).
            if let touch = request["touch"] as? Bool { ManagerKeep.testAnswer = touch }
            if request["new_session"] as? Bool == true { ManagerKeep.forgetSession() }
            // A manager whose app macOS stopped: on, loaded, filling nothing.
            if let id = request["stop"] as? String { Extensions.shared.macOSStopped(id) }
            if let sheet = request["sheet"] as? Bool {
                connections.opensOn = request["on"] as? String
                connections.opensSetUp = request["at"] as? String == "setup"
                connections.connecting = sheet
            }
            // The page's other cards: an unlock password, Disconnect's question.
            if let which = request["card"] as? String, let id = request["on"] as? String {
                connections.card = which == "disconnect" ? .disconnect(id) : .password(id)
            }
            connections.look()
            let source = browser.prefs.passwordSource
            let card: String = {
                switch connections.card {
                case nil:
                    let opened = SettingsWindow.shared.model?.opened
                    if let id = PasswordManagersPlace.manager(opened) { return "connect:" + id }
                    return connections.connecting ? "pick" : ""
                case .password(let id): return "password:" + id
                case .disconnect(let id): return "disconnect:" + id
                }
            }()
            // Settings' Offer to save passwords as drawn now, and as it is
            // drawn for another saver ("offer_switch_for", Apple Passwords
            // read as connected natively, which a Dev build is not entitled to).
            let offer = source.offerSwitch(saves: browser.prefs.savesPasswords)
            var asked: [String: Any] = [:]
            if let other = request["offer_switch_for"] as? String {
                let id = PasswordManagers.canonical(other)
                let drawn = PasswordManagers.Source(yab: source.yab, saver: id, asksForApple: id == PasswordManagers.apple)
                    .offerSwitch(saves: browser.prefs.savesPasswords)
                asked = ["on": drawn.on, "enabled": drawn.enabled]
            }
            answer(["yab": source.yab, "saver": source.saver ?? "", "saved": saved,
                    "offer_switch": ["on": offer.on, "enabled": offer.enabled], "offer_switch_for": asked, "kept": ManagerKeep.last, "session": ManagerKeep.approved, "keep_trace": ManagerKeep.trace,
                    "card": card, "card_ms": connections.shownMs ?? -1, "here": connections.here,
                    "key_is_settings": NSApp.keyWindow === SettingsWindow.shared.window, "settings_open": SettingsWindow.shared.window?.isVisible ?? false,
                    "listed": ManagerExtensions.shared.installed.map { ["id": $0.id, "enabled": $0.enabled] as [String: Any] },
                    "found": Dictionary(uniqueKeysWithValues: PasswordManagers.providers.compactMap { provider in
                        PasswordManagers.found(provider.id).map { (provider.id, $0) } }),
                    "connected": connections.list.map { ["provider": $0.provider, "mode": $0.mode.rawValue, "row": connections.row($0.provider).words] }])
            return
        case "frames-eval":
            // Every frame of a tab, extensions' and sandboxed ones too, asked
            // the same script in the page's world: what each says.
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let script = request["js"] as? String ?? "return location.href"
            let page = tab.page
            page.childFrames { frames in
                var out: [[String: Any]] = []
                let group = DispatchGroup()
                for frame in frames.prefix(20) {
                    group.enter()
                    page.call(script, in: .page, frame: frame) { result in
                        let value = (try? result.get()).map { "\($0)" } ?? "(unread)"
                        out.append(["origin": "\(frame.origin.scheme)://\(frame.origin.host)",
                                    "url": frame.url?.absoluteString ?? "", "value": value])
                        group.leave()
                    }
                }
                group.notify(queue: .main) { MainActor.assumeIsolated { answer(["frames": out]) } }
            }
            return
        case "manager-stage":
            // The managers as a test world shows them, for pictures of every
            // state (evals/extensions/password_menu.py): [{provider, users,
            // unlocking, hybrid, busy}], or none to read them for real.
            let staged = (request["managers"] as? [[String: Any]])?.map { item -> SuggestRows.Manager in
                let id = item["provider"] as? String ?? ""
                let logins = (item["users"] as? [String] ?? []).enumerated().map {
                    ManagerVault.Login(provider: id, item: "\($0.offset)", title: $0.element, user: $0.element, urls: [])
                }
                let entries = (item["entries"] as? [String] ?? []).map { ManagerMenus.Entry(provider: id, title: $0, detail: "") }
                return SuggestRows.Manager(provider: id, logins: logins, entries: entries, locked: item["locked"] as? Bool ?? false,
                                           unlocking: item["unlocking"] as? Bool ?? false,
                                           hybrid: item["hybrid"] as? Bool ?? false, busy: item["busy"] as? Bool ?? false)
            }
            ManagerLists.shared.staged = staged
            if let saver = request["saver"] as? String { ManagerLists.shared.stagedSaver = saver.isEmpty ? nil : saver }
            ManagerLists.shared.stagedInsecure = request["insecure"] as? Bool
            ManagerLists.shared.forget()
            if let tab = browser.active { browser.reopenList(tab.id) }
        case "passkey-stage":
            // A test world's passkeys for conditional gets on Chromium tabs,
            // read in place of the Mac's own (never a real passkey):
            // [{id, user, provider}], or none to read the Mac's.
            guard Store.testing else { answer(["error": "passkey-stage needs a test run"]); return }
            ChromiumWebAuthn.staged = (request["passkeys"] as? [[String: Any]])?.map {
                (id: $0["id"] as? String ?? "", user: $0["user"] as? String ?? "", provider: $0["provider"] as? String ?? "")
            }
        case "press-plate":
            // Yab's plate in the box, as clicked.
            guard let plate = browser.fieldPlate else { answer(["error": "no plate in the box"]); return }
            browser.pressPlate(plate.tab)
        case "pick-row":
            // A row of the list, any source, as clicked.
            guard let list = browser.suggesting else { answer(["error": "no list under the box"]); return }
            let at = request["index"] as? Int ?? 0
            guard list.list.indices.contains(at) else { answer(["error": "no row \(at)"]); return }
            browser.chooseRow(list.list[at])
        case "agent-filling":
            // What an agent's sign-in from a manager says under the box.
            guard let tab = browser.active, let spot = tab.fieldSpot else { answer(["error": "no box"]); return }
            browser.agentFilling = (request["on"] as? Bool ?? true)
                ? AgentFilling(tab: tab.id, spot: spot, title: request["title"] as? String ?? "Claude is signing in",
                               detail: request["detail"] as? String ?? "", dark: tab.fieldDark)
                : nil
        case "manager-alias":
            // A test extension standing for a manager (password_menu.py's
            // fixture menu): its local id read as that manager's.
            guard Store.testing, let local = request["id"] as? String, let as_ = request["as"] as? String else {
                answer(["error": "manager-alias needs a test run, id and as"]); return
            }
            PasswordManagers.testAliases.withLock { $0[local] = as_ }
        case "pick-login":
            // A row of the list under the box, as clicked.
            guard let list = browser.suggesting else { answer(["error": "no list under the box"]); return }
            let at = request["index"] as? Int ?? 0
            guard list.logins.indices.contains(at) else { answer(["error": "no row \(at)"]); return }
            browser.choose(list.logins[at])
        case "seed-world":
            // A person's own things as a demo world starts with them
            // (demos/world.py): logins, two-factor keys, cards, addresses and
            // downloads, made by this build so its keychain reads them back.
            guard Store.testing else { answer(["error": "seed-world only works in a test world"]); return }
            answer(Bench.seedWorld(browser, request))
            return
        case "seed-shelf":
            // Files and Purchases as the concept draws them: a lease from a
            // landlord's mail with its words inside, a W-9 sent, a passport
            // scan given to a site, and a month of subscriptions and orders.
            guard Store.testing else { answer(["error": "seed-shelf only works in a test world"]); return }
            answer(Bench.seedShelf(browser))
            return
        case "seed-files":
            guard Store.testing, let page = browser.active?.address else {
                answer(["error": "seed-files needs a page in a test world"]); return
            }
            for name in ["receipt-one.pdf", "receipt-two.pdf"] {
                let url = Store.file(name)
                try? Data("%PDF-1.4\n%%EOF\n".utf8).write(to: url)
                browser.loot.add(Keep(name: name, from: page.host() ?? "", path: url.path,
                                      date: Date(), page: page, pageTitle: "File test"))
            }
        case "clear-places":
            guard Store.testing else { answer(["error": "clear-places only works in a test world"]); return }
            Bench.clearPlaces(browser)
        case "seed-clips":
            Clips.shared.seed(request["count"] as? Int ?? 1000)
        case "cost":
            // Each word typed into the field as a key would put it there,
            // timed on the main thread: what one keystroke costs.
            var costs: [Double] = []
            for word in request["words"] as? [String] ?? [] {
                var start = timespec(), end = timespec()
                clock_gettime(CLOCK_THREAD_CPUTIME_ID, &start)
                browser.typed = word
                clock_gettime(CLOCK_THREAD_CPUTIME_ID, &end)
                costs.append(Double(end.tv_sec - start.tv_sec) * 1000 + Double(end.tv_nsec - start.tv_nsec) / 1e6)
            }
            answer(["ms": costs])
            return
        case "clear-clips":
            Clips.shared.clear()
            for clip in Clips.shared.items { Clips.shared.delete(clip) }
        case "state":
            break
        case "instant":
            answer(Bench.fieldState(browser))
            return
        default:
            answer(["error": "box: state, t, l, plus, type, key, reset, close, board, clear-clips"])
            return
        }
        later { answer(Bench.fieldState(browser)) }
    }

    /// The field and the row of tabs, as a script checks them.
    static func fieldState(_ browser: Browser) -> [String: Any] {
        let query = browser.query
        let editor = Links.window?.firstResponder as? NSTextView
        let fieldHost = browser.fieldHost ?? Links.window
        let hostEditor = fieldHost?.firstResponder as? NSTextView
        let hostField = hostEditor?.delegate as? NSTextField
        return [
            "showing": browser.fieldShowing,
            "window": Links.window?.windowNumber ?? 0,
            "editing": browser.editing,
            "fresh": browser.fresh,
            "askingNew": browser.askingNew,
            "typed": browser.typed,
            "completed": browser.completed,
            "untouched": browser.untouched?.absoluteString ?? "",
            "focused": editor?.isFieldEditor == true,
            "fieldGuestID": browser.fieldGuest?.id.uuidString ?? "",
            "fieldHostWindow": browser.fieldHost?.windowNumber ?? 0,
            "fieldKeyWindow": NSApp.keyWindow?.windowNumber ?? 0,
            "fieldHostFocused": fieldHost?.isKeyWindow == true && hostEditor?.isFieldEditor == true
                && hostField?.delegate is AddressField.Coordinator,
            "scope": query.scope?.id ?? "",
            "current": query.current ?? -1,
            "picked": query.picked ?? -1,
            "pointed": query.pointed ?? -1,
            // What the reader made of the words (Actions in the Field).
            "reading": RequestModel.shared.said(browser.typed.trimmingCharacters(in: .whitespacesAndNewlines)),
            "offers": query.offers.map { ["key": $0.key, "title": $0.title, "kind": "\($0.kind)", "url": $0.url?.absoluteString ?? "",
                                          "favorite": $0.favorite, "bookmarked": $0.bookmarked, "engine": $0.engine, "section": browser.quietSection($0) ?? ""] as [String: Any] },
            "active": browser.active.map { $0.id.uuidString.prefix(8) } ?? "",
            "activeBlank": browser.active?.isBlank ?? true,
            "activeURL": browser.active?.address?.absoluteString ?? "",
            "tabs": browser.tabs.map { ["id": String($0.id.uuidString.prefix(8)), "url": $0.address?.absoluteString ?? "", "blank": $0.isBlank, "label": $0.label, "instant": $0.instantState.map { $0 == .searching ? "searching" : "loading" } ?? ""] as [String: Any] },
            "refusals": browser.refusals,
            "toast": browser.toaster.shown ? browser.toaster.words : "",
            // The bookmarks' row in sight (⌃⌘B), and how many are kept.
            "shelf": browser.shelfShown,
            "bookmarks": browser.bookmarks.count,
            "place": query.place?.rawValue ?? "",
            "spot": query.spot,
            "filter": query.clipFilter.rawValue,
            "emojiWords": browser.emojiWords ?? "-",
            "clips": browser.placeClips.prefix(12).map { ["text": $0.text, "kind": $0.kind.rawValue, "times": $0.times, "pinned": $0.pinned, "app": $0.app ?? "", "page": $0.page?.absoluteString ?? ""] },
            "history": Clips.shared.items.count,
            "clipsMainRead": ["reads": Clips.shared.mainRead.reads, "last_ms": Clips.shared.mainRead.lastMs, "worst_ms": Clips.shared.mainRead.worstMs] as [String: Any],
            "emoji": browser.placeEmoji.prefix(14).map(\.glyph),
            "actions": browser.fieldActions.map(\.title),
            "featured": browser.fieldActions.filter(\.featured).map(\.title),
            // What ⇥ asks, as the field's end says it ("Ask Claude"), or "".
            "tabAsks": browser.tabAsks?.key ?? "",
            "ending": browser.ending ?? "",
            "menu": Browser.shownActions,
            "acting": query.acting ?? -1,
            // Each row's frame on screen, for a hand to right-click.
            "rowFrames": FieldRowMenu.frames,
            "shown": browser.shownActions.map(\.title),
            "actionWords": query.actionWords,
            // With the icon its tile draws, averaged, "" for a letter or a mark.
            "items": browser.placeItems.prefix(16).map { ["title": $0.title, "section": $0.section, "source": $0.source, "faded": $0.faded,
                                                          "icon": Scope.average(of: PlaceTileView.picture($0.tile))?.hex ?? ""] },
            "placeFilter": query.placeFilter,
            "target": browser.placeTarget.map { ($0.refused ? "refused:" : "into:") + $0.what + ($0.host.isEmpty ? "" : " · " + $0.host) } ?? "",
            "empty": browser.placeEmpty.map { ["title": $0.title, "detail": $0.detail, "actions": $0.actions.map(\.title), "sources": $0.sources.count] } ?? [:],
            "revealed": query.revealed?.text ?? "",
            "form": query.form.map { ["login": $0.login ?? "", "wallet": $0.wallet?.group == .card ? "card" : $0.wallet == nil ? "" : "address",
                                        "file": $0.file?.label ?? "", "multiple": $0.file?.multiple ?? false] as [String: Any] } ?? [:],
            "fileWaiting": browser.fileAnswer != nil,
            "fileFolder": browser.query.stock.fileFolder.map(RecentFiles.title(of:)) ?? "",
            "shotFolders": RecentFiles.shotFolders.map { $0.0.path },
            "choosingFilter": query.choosingFilter,
            "choosingAbout": query.choosingAbout,
            "fileSelected": browser.fileSelected.sorted().map { URL(fileURLWithPath: $0).lastPathComponent },
            "concealed": NSPasteboard.general.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ?? false,
            "transient": NSPasteboard.general.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) ?? false,
            "fileOnBoard": NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first.map { ($0 as? URL)?.lastPathComponent ?? "" } ?? "",
            "card": Self.cardBounds(for: browser),
            "pageTyping": query.pageTyping,
            "clipboard": NSPasteboard.general.string(forType: .string) ?? "",
            "responder": Links.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "edit": query.edit.map { ["title": $0.title, "focus": $0.focus, "why": $0.why, "values": $0.lines.map(\.value),
                                     "ghosts": $0.lines.map(\.ghost), "fills": $0.fillTab != nil,
                                     "save": browser.editActions.first?.title ?? "",
                                     // Only state, never the login draft's secret.
                                     "canSave": $0.passwordEditor?.model.canSave ?? true,
                                     "waiting": $0.passwordEditor?.waiting ?? false,
                                     "passwordEntered": !($0.passwordEditor?.model.password.isEmpty ?? true),
                                     "showing": $0.passwordEditor?.model.showing ?? false,
                                     "error": $0.passwordEditor?.model.error ?? ""] as [String: Any] } ?? [:],
        ]
    }
}

extension Bench {
    /// What the box's places are shown with in a test world.
    @MainActor static func seedPlaces(_ browser: Browser, many: Int = 0) {
        clearPlaces(browser)
        let folder = Store.file("seeded-downloads")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let files: [(String, String, String, String, TimeInterval)] = [
            ("hero@2x.png", "cdn.example.com", "https://yetanotherbrowser.com/", "Yab, yet another browser", -86400 * 3),
            ("design-assets.zip", "figma.com", "https://www.figma.com/design/launcher", "Launcher, Export", -86400),
            ("invoice-2026-08.pdf", "files.stripe.com", "https://dashboard.stripe.com/invoices/in_1", "Acme Corp, Billing, August", -600),
        ]
        for (name, host, page, title, ago) in files {
            let file = folder.appendingPathComponent(name)
            // Real files, so Quick Look draws them: a picture, a page.
            if name.hasSuffix(".png") {
                let image = NSImage(size: NSSize(width: 1200, height: 800), flipped: false) { rect in
                    NSGradient(colors: [NSColor.systemOrange, NSColor.systemPink, NSColor.systemBlue])?.draw(in: rect, angle: -35)
                    ("yab" as NSString).draw(at: NSPoint(x: 80, y: 320), withAttributes: [.font: NSFont.systemFont(ofSize: 180, weight: .bold), .foregroundColor: NSColor.white])
                    return true
                }
                if let tiff = image.tiffRepresentation, let bits = NSBitmapImageRep(data: tiff) { try? bits.representation(using: .png, properties: [:])?.write(to: file) }
            } else if name.hasSuffix(".pdf") {
                let data = NSMutableData()
                var box = CGRect(x: 0, y: 0, width: 612, height: 792)
                if let consumer = CGDataConsumer(data: data as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) {
                    pdf.beginPDFPage(nil)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
                    ("Invoice · Acme Corp" as NSString).draw(at: NSPoint(x: 60, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold)])
                    for line in 0..<14 {
                        NSColor(white: 0.85, alpha: 1).setFill()
                        NSRect(x: 60, y: 640 - line * 32, width: line % 3 == 2 ? 300 : 490, height: 12).fill()
                    }
                    ("Total  $48,291.00" as NSString).draw(at: NSPoint(x: 60, y: 120), withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold)])
                    NSGraphicsContext.restoreGraphicsState()
                    pdf.endPDFPage()
                    pdf.closePDF()
                }
                try? (data as Data).write(to: file)
            } else {
                try? Data(repeating: 7, count: 142_000).write(to: file)
            }
            browser.loot.add(Keep(name: name, from: host, path: file.path, date: now.addingTimeInterval(ago), page: URL(string: page), pageTitle: title))
        }
        // A long list, for timing a walk down it: copies of the picture and
        // the page under other names, each its own file for Quick Look.
        for index in 0..<(many) {
            let from = folder.appendingPathComponent(index % 2 == 0 ? "hero@2x.png" : "invoice-2026-08.pdf")
            let name = index % 2 == 0 ? "photo-\(index).png" : "statement-\(index).pdf"
            let file = folder.appendingPathComponent(name)
            try? FileManager.default.copyItem(at: from, to: file)
            browser.loot.add(Keep(name: name, from: "example.com", path: file.path, date: now.addingTimeInterval(-Double(index) * 4000),
                                  page: URL(string: "https://example.com/\(index)"), pageTitle: "Page \(index)"))
        }
        browser.loot.add(Keep(name: "old-report.pdf", from: "docs.example.com", path: folder.appendingPathComponent("gone/old-report.pdf").path,
                              date: now.addingTimeInterval(-86400 * 9), page: URL(string: "https://docs.example.com/reports"), pageTitle: "Reports"))
        for (host, user, password) in [("github.com", "sam@mail.example", "correct horse battery"), ("stripe.com", "sam@mail.example", "s3cret-stripe"),
                                       ("figma.com", "samrivera", "figma-pass-1"), ("linear.app", "sam@mail.example", "linear-pass-2")] {
            _ = Vault.save(host: host, user: user, password: password, used: now.addingTimeInterval(-3600))
        }
        // The test's own sign-in page, served in the clear on this Mac.
        _ = Vault.save(host: "localhost", user: "tester", password: "hunter2", used: now.addingTimeInterval(-60), clear: true)
        OneTime.save("otpauth://totp/GitHub:samrivera?secret=JBSWY3DPEHPK3PXP&issuer=GitHub", host: "github.com", user: "sam@mail.example")
        _ = Wallet.save(SavedCard(id: "seed-visa", number: "4242424242424242", last4: "4242", brand: "Visa", name: "Sam Rivera",
                                  month: 9, year: 2028, used: now.addingTimeInterval(-7200), saved: nil, usedOn: "northwind.shop"))
        _ = Wallet.save(SavedCard(id: "seed-amex", number: "378282246310005", last4: "0005", brand: "American Express", name: "Sam Rivera",
                                  month: 2, year: 2024, used: nil, saved: nil))
        var home = StreetAddress(id: "seed-home")
        home.name = "Sam Rivera"
        home.street = "1 Market St\nSuite 300"
        home.city = "San Francisco"
        home.region = "CA"
        home.postal = "94105"
        home.country = "United States"
        home.phone = "+1 415 555 0100"
        home.email = "sam@mail.example"
        _ = Wallet.save(home)
        let tab = browser.active?.id ?? UUID()
        for (link, title) in [("https://github.com/example/yab/pull/418", "Clipboard history in the field #418 · example/yab"),
                              ("https://dashboard.stripe.com/test/revenue", "MRR · Stripe Dashboard"),
                              ("https://en.wikipedia.org/wiki/Liquid", "Liquid · Wikipedia")] {
            if let url = URL(string: link) { Diary.shared.visit(url, title: title, tab: tab) }
        }
    }

    /// What `box seed-world` keeps, from the request's lists, after the
    /// world's own are cleared. Times are seconds ago: "used", "ago".
    @MainActor static func seedWorld(_ browser: Browser, _ request: [String: Any]) -> [String: Any] {
        clearPlaces(browser)
        let now = Date()
        func ago(_ item: [String: Any], _ key: String) -> Date? {
            (item[key] as? Double).map { now.addingTimeInterval(-$0) }
        }
        var logins = 0, codes = 0, cards = 0, addresses = 0, downloads = 0
        for login in request["logins"] as? [[String: Any]] ?? [] {
            guard let host = login["host"] as? String, let user = login["user"] as? String,
                  let password = login["password"] as? String else { continue }
            // "space": the name of the Space it was saved in, none for shared.
            let space = (login["space"] as? String).flatMap { name in browser.spaces.first { $0.name.lowercased() == name.lowercased() }?.id }
            if Vault.save(host: host, user: user, password: password, used: ago(login, "used"), clear: login["clear"] as? Bool ?? false, space: space) {
                logins += 1
            }
            if let key = login["totp"] as? String, OneTime.save(key, host: host, user: user) { codes += 1 }
        }
        for item in request["cards"] as? [[String: Any]] ?? [] {
            let digits = (item["number"] as? String ?? "").filter(\.isNumber)
            guard !digits.isEmpty else { continue }
            var card = SavedCard(id: item["id"] as? String ?? UUID().uuidString, number: digits, last4: String(digits.suffix(4)),
                                 brand: item["brand"] as? String ?? "", name: item["name"] as? String ?? "",
                                 month: item["month"] as? Int ?? 1, year: item["year"] as? Int ?? 2030,
                                 used: ago(item, "used"), saved: nil)
            card.nickname = item["nickname"] as? String ?? ""
            card.usedOn = item["usedOn"] as? String ?? ""
            card.csc = item["csc"] as? String ?? ""
            if Wallet.save(card) { cards += 1 }
        }
        for item in request["addresses"] as? [[String: Any]] ?? [] {
            var address = StreetAddress(id: item["id"] as? String ?? UUID().uuidString)
            func text(_ key: String) -> String { item[key] as? String ?? "" }
            address.name = text("name")
            address.organization = text("organization")
            address.street = text("street")
            address.city = text("city")
            address.region = text("region")
            address.postal = text("postal")
            address.country = text("country")
            address.phone = text("phone")
            address.email = text("email")
            address.used = ago(item, "used")
            address.source = item["source"] as? String
            address.usedOn = item["usedOn"] as? String
            address.found = item["found"] as? String
            if Wallet.save(address) { addresses += 1 }
        }
        for item in request["downloads"] as? [[String: Any]] ?? [] {
            guard let name = item["name"] as? String, let path = item["path"] as? String else { continue }
            browser.loot.add(Keep(name: name, from: item["from"] as? String ?? "", path: path, date: ago(item, "ago") ?? now,
                                  page: (item["page"] as? String).flatMap(URL.init(string:)), pageTitle: item["title"] as? String))
            downloads += 1
        }
        // Local pages counted as a meeting's call and as a calendar, by host,
        // before any tab of theirs is open (call meeting / calendar take a tab).
        for host in request["meetingHosts"] as? [String] ?? [] { CallLink.benchHosts.insert(host.lowercased()) }
        for host in request["calendarHosts"] as? [String] ?? [] { Meetings.benchCalendars.insert(host.lowercased()) }
        return ["logins": logins, "codes": codes, "cards": cards, "addresses": addresses, "downloads": downloads]
    }

    @MainActor static func clearPlaces(_ browser: Browser) {
        browser.loot.forgetAll()
        try? FileManager.default.removeItem(at: Store.file("seeded-downloads"))
        for entry in Vault.entries() {
            Vault.forget(host: entry.host, user: entry.user)
            OneTime.forget(host: entry.host, user: entry.user)
        }
        Wallet.cards().forEach { Wallet.forget(card: $0.id) }
        Wallet.addresses().forEach { Wallet.forget(address: $0.id) }
    }
    private static func cardBounds(for browser: Browser) -> [CGFloat] {
        let card = Omnibox.probeCards[ObjectIdentifier(browser)] ?? .zero
        return [card.minX, card.minY, card.width, card.height]
    }

}
