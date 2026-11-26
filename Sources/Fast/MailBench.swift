import AppKit
import WebKit

// `agent-mail-space`: the bench driving mail's own page the way a person
// does, for mail's evals and films (evals/mail, evals/mail-motion). Test
// driving only: a test run or Yab Dev (Bench.testVerbs).

extension Bench {
    static let mailSpaceVerbs: [String: AgentHandler] = [
        "agent-mail-space": { $0.handleAgentMailSpace($1) },
    ]

    func handleAgentMailSpace(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // Mail's space (MailSpace): in, out, a list or an account chosen,
        // a Kept row clicked, a thread opened, as the column does them;
        // then what the column shows.
        let list = MailList.shared
        switch request["act"] as? String ?? "" {
        case "enter": browser.enterMail()
        case "leave": browser.leaveMail()
        // A row of Now about this yab://mail#thread= address, taken (MailThreadPeek).
        case "mailrow": if let url = URL(string: request["value"] as? String ?? "") { browser.mailRow(url, hint: nil) }
        // Only whether the card is up and where you are, at once: cheap enough
        // to ask in a loop while the main thread is being measured.
        case "peek":
            let name = { (id: UUID) in id == Space.mailID ? "Mail" : browser.spaces.first { $0.id == id }?.name ?? id.uuidString }
            answer(["threadPeekUp": browser.threadPeek != nil, "inMail": browser.inMail, "space": name(browser.spaceID),
                    "back": name(MailSpaceState.shared.back), "spaces": browser.spaces.map(\.name),
                    "active": browser.active?.address?.absoluteString ?? ""])
            return
        case "split":
            // As the column's row is clicked: mail's page back over a tab of its space.
            browser.showMailPage()
            list.split = request["value"] as? String ?? "needs"
        // A tab's row under Tabs pressed, as its tap does (Browser.tapTab).
        case "taptab":
            let key = (request["value"] as? String ?? "").lowercased()
            if !key.isEmpty, let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(key) }) { browser.tapTab(tab) }
        case "account": list.account = request["value"] as? String ?? "all"
        // Show in All Accounts for an account (`value`), `on` true or false,
        // as its switch in Settings › Mail turns it.
        case "inall": MailCenter.shared.setInAll(request["value"] as? String ?? "", request["on"] as? Bool ?? true)
        case "choose": list.choosing = true
        case "columnscroll":
            // The column's lists scrolled, "top", "end" or to a y, by
            // their own scroll view: the tallest at the column's edge.
            var found: NSScrollView?
            func walk(_ view: NSView) {
                if let scroll = view as? NSScrollView, scroll.frame.height > 0,
                   scroll.convert(scroll.bounds, to: nil).minX < 40, scroll.bounds.width <= browser.prefs.sideWidth + 1,
                   (scroll.documentView?.frame.height ?? 0) > (found?.documentView?.frame.height ?? 0) { found = scroll }
                view.subviews.forEach(walk)
            }
            if let content = Links.window?.contentView { walk(content) }
            if let scroll = found, let doc = scroll.documentView {
                // Past its margins, where the rows rest and stop.
                let insets = scroll.contentInsets
                let room = scroll.contentView.bounds.height
                let end = max(0, doc.frame.height - room + insets.top + insets.bottom)
                let asked = request["value"] as? String ?? "top"
                let y = asked == "end" ? end : asked == "top" ? 0 : min(end, CGFloat(Double(asked) ?? 0))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? y - insets.top : end - y - insets.bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            answer(["scrolled": found != nil, "insets": found.map { [Double($0.contentInsets.top), Double($0.contentInsets.bottom)] } ?? [],
                    "doc": Double(found?.documentView?.frame.height ?? 0), "room": Double(found?.contentView.bounds.height ?? 0)])
            return
        // Mail after Town (docs/mail.md): the offers worked out now,
        // the one over the list in front taken, a routine on a split's
        // mail set as its head's When Mail Comes… sets it.
        case "offers": list.refreshOffers()
        // The sorting card's Got It, as its button puts it away.
        case "gotit": list.doneSorting()
        case "offertake": if let offer = list.offer(over: list.split) { MailDesk.shared.take(offer) }
        case "routine":
            let id = request["split"] as? String ?? list.split
            Routines.shared.onMail(split: id, title: list.split(id)?.title ?? id, words: request["value"] as? String ?? "",
                                   asks: request["asks"] as? Bool ?? true)
        case "list":
            // A search kept as a split, as the field's New Split keeps it.
            let q = request["value"] as? String ?? ""
            list.saveList(title: request["title"] as? String ?? q, q: q)
        case "unlist": list.dropList("q:" + (request["value"] as? String ?? ""))
        // Splits (MailSplits): where one's mail goes ("off", "also", "only",
        // "skip"), whether it notifies, its rules; one dragged over
        // another in the column; empty ones hidden or not; a list by its
        // address (yab://mail#list=), as the new tab's line opens one.
        case "splitset":
            let id = request["value"] as? String ?? ""
            if let mode = request["mode"] as? String { list.setMode(mode, for: id) }
            if let notify = request["notify"] as? Bool { list.change(id) { $0.notify = notify } }
            if let q = request["q"] as? String { list.change(id) { $0.q = q } }
        case "splitmove": list.move(request["value"] as? String ?? "", to: request["to"] as? String ?? "")
        case "hideempty": list.hideEmpty = request["value"] as? Bool ?? true
        case "openlist":
            var url = URLComponents(string: "yab://mail")!
            url.fragment = "list=" + (request["value"] as? String ?? "")
            browser.enterMail(url.url)
        case "did":
            // An agent's Do It finished with this reply, as mail_draft leaves it.
            _ = MailAgent.draft(MailCenter.shared, ["thread": request["value"] as? String ?? "", "body": request["body"] as? String ?? ""])
        case "ask":
            // Claude asked from an empty reply: these words, ↩.
            MailDesk.shared.ask(request["value"] as? String ?? "")
        case "rewrite": MailDesk.shared.rewrite(request["value"] as? String ?? "shorter")
        case "person": MailSearch.shared.takePerson(request["value"] as? Int ?? 0)
        case "searchtype":
            // Words typed in the search, up over the column.
            MailDesk.shared.searching = true
            DispatchQueue.main.async { MailSearch.shared.typed = request["value"] as? String ?? "" }
        case "searchtake": MailSearch.shared.take(request["value"] as? Int)
        case "searchmove": MailSearch.shared.move(request["value"] as? Int ?? 1)
        case "searchforget": _ = MailSearch.shared.forget()
        case "searchfocus": MailDesk.shared.searching = true
        case "draft": list.startDraft()
        case "drafttitle": list.editDraft { $0.title = request["value"] as? String ?? "" }
        case "draftmake": list.makeDraft()
        case "draftadd":
            let rule = MailRule(kind: request["kind"] as? String ?? "words", value: request["value"] as? String ?? "")
            list.editDraft { $0.q = MailRule.line($0.rules + [rule]) }
        case "draftkeep": list.keepDraft()
        case "draftdiscard": list.discardDraft()
        case "fieldtype": browser.replaceTyped(request["value"] as? String ?? "")
        case "fieldtake": browser.takeMail(request["value"] as? String ?? "")
        case "group": list.change(list.split) { $0.group = (request["value"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        case "summarize": list.summarize(list.split, force: true)
        case "page":
            let url = request["value"] as? String ?? "", title = request["title"] as? String ?? url
            list.change(list.split) { $0.pages = ($0.pages ?? []) + [MailList.Page(url: url, title: title)] }
        case "addrule":
            let rule = MailRule(kind: request["kind"] as? String ?? "words", value: request["value"] as? String ?? "")
            list.change(list.split) { $0.q = MailRule.line($0.rules + [rule]) }
        // A split's filters (MailFilters): a pill's menu, + Add Filter's or
        // For now's opened as a click opens it; words in its field; a row
        // taken as ↩ or a click takes it; New Split's library, a card
        // added; ⌘K's Add to Split, a rule of a thread into a split.
        case "filteropen":
            let what = request["value"] as? String ?? ""
            let menu = MailFilterMenu.shared
            if what == "picker" { menu.toggle(.picker) } else if what == "temp" { menu.toggle(.temp) }
            else if let filter = MailFilter(rawValue: what) { menu.toggle(.filter(filter)) }
        case "filterpick": if let filter = MailFilter(rawValue: request["value"] as? String ?? "") { MailFilterMenu.shared.pick(filter) }
        case "filtertype": MailFilterMenu.shared.typed = request["value"] as? String ?? ""
        case "filtertake":
            let menu = MailFilterMenu.shared
            let rows = menu.rows()
            let title = request["value"] as? String ?? (request["value"] as? Int).map(String.init) ?? ""
            if let row = rows.first(where: { $0.title == title }) ?? (Int(title).flatMap { rows.indices.contains($0) ? rows[$0] : nil }) { menu.take(row) }
        case "filterdrop": MailFilterMenu.shared.dropLast()
        case "filterclose": MailFilterMenu.shared.close()
        case "library": MailDesk.shared.field(.library)
        case "addtosplit":
            let rule = MailRule(kind: request["kind"] as? String ?? "with", value: request["rule"] as? String ?? "")
            MailDesk.shared.addToSplit(request["value"] as? String ?? "", rule: rule, said: request["said"] as? String ?? rule.value)
        case "unpin":
            // The mail pin unpinned by hand, as its menu does.
            if let pin = browser.tabs.first(where: { $0.pin != nil && MailPage.isMail($0.pending ?? $0.address) }) { browser.unpin(pin) }
        case "command": MailDesk.shared.command(request["value"] as? String ?? "")
        case "unblock":
            // A sender let in again, as Settings › Mail's Unblock does.
            for engine in MailCenter.shared.engines.values { engine.store.unblock(request["value"] as? String ?? "") }
            MailCenter.shared.touch()
        // The column's labels (MailLabels): the section closed or open, a
        // label opened or closed over those under it, by its name.
        case "labelsfold": MailLabels.shared.fold()
        case "labelopen": MailLabels.shared.toggle(request["value"] as? String ?? "")
        // A label's right-click menu (MailLabelMenu), by the label's
        // name, the heading's with none: its lines, or one pressed by
        // its title ("Move To/Hiring"); the field in a row done with
        // these words, as ↩ does.
        case "labelmenu", "labelpress":
            let name = request["value"] as? String ?? ""
            let lines = name.isEmpty ? MailLabels.shared.headingLines : MailLabels.shared.lines(name)
            if request["act"] as? String == "labelmenu" {
                func said(_ lines: [MailLabelLine]) -> [[String: Any]] {
                    lines.map { ["kind": "\($0.kind)", "title": $0.title, "mark": $0.mark ?? "", "enabled": $0.enabled, "sub": said($0.sub)] }
                }
                answer(["lines": said(lines)])
                return
            }
            guard let line = MailLabelLine.find(request["line"] as? String ?? "", in: lines), line.enabled, let run = line.run else {
                answer(["error": "no line \(request["line"] as? String ?? "") in \(name.isEmpty ? "the heading's" : name + "'s") menu"])
                return
            }
            run()
        case "labelname": answer(["kept": MailLabels.shared.finish(request["value"] as? String)]); return
        case "older": MailDesk.shared.older()
        case "turnwho": MailDesk.shared.turnWho()
        case "keepsearch": MailDesk.shared.keepSearch()
        case "unwho": MailDesk.shared.who = nil
        case "earlier": MailDesk.shared.earlierOpen = true
        case "walk": MailDesk.shared.walk(request["value"] as? Int ?? 1)
        case "newer": MailDesk.shared.takeNewer()
        case "step": browser.stepSpace(request["value"] as? Int ?? 1)
        // Mail among the spaces: dragged to a place in the foot, ⌃N, its
        // emoji, and ⌘T's Mail command.
        case "spaceplace": browser.moveInOrder(Space.mailID, to: request["value"] as? Int ?? 0)
        case "spacenumber": browser.switchSpace(index: (request["value"] as? Int ?? 1) - 1)
        case "spaceemoji": browser.setSpaceIcon(Space.mailID, to: request["value"] as? String ?? "✉️")
        case "fieldmail": if Command.mail.available(in: browser) { Command.mail.run(in: browser) }
        // Mail's look by a swatch: kept as Settings › Spaces or the look card
        // keeps it ("spacelook"), or only worn as Appearance wears it, for
        // leaving Mail to keep ("spacewear").
        case "spacelook", "spacewear":
            var paint = SpacePaint(browser.prefs)
            paint.swatch = request["value"] as? String ?? "sky"
            if request["act"] as? String == "spacelook" { browser.setSpacePaint(Space.mailID, to: paint) } else { paint.wear(browser.prefs) }
        case "people":
            // The To field's suggestions for these words.
            answer(["people": MailDesk.shared.people(matching: request["value"] as? String ?? "", limit: 4).map(\.said)])
            return
        case "field":
            // The field's Mail place in a mode, as its keys raise it.
            let modes: [String: MailFieldContext.Mode] = ["commands": .commands, "list": .list, "rewrite": .rewrite, "remind": .remind,
                                                         "followup": .followup, "zero": .zero, "bulk": .bulk,
                                                         "label": .label, "move": .move, "golabel": .goLabel, "from": .from]
            MailDesk.shared.field(modes[request["value"] as? String ?? ""] ?? .commands)
        case "kept":
            let title = request["value"] as? String ?? ""
            if let item = list.kept.first(where: { $0.title == title || $0.title.hasSuffix(title) }) { browser.openKept(item) }
        case "cursor":
            // The list's cursor on a row, by its thread or subject, as J and K leave it.
            let id = request["value"] as? String ?? ""
            if let at = MailDesk.shared.rows.firstIndex(where: { $0.thread == id || $0.subject == id }) { MailDesk.shared.sel = at }
        case "row":
            // A row clicked in the list, by its thread.
            let id = request["value"] as? String ?? ""
            if let row = MailDesk.shared.rows.first(where: { $0.thread == id || $0.subject == id }) { MailDesk.shared.show(row) }
        case "type":
            // Words in the reply or the new mail, as typed there.
            if let to = request["to"] as? String { MailDesk.shared.draft?.to = to }
            if let cc = request["cc"] as? String { MailDesk.shared.draft?.cc = cc }
            if let bcc = request["bcc"] as? String { MailDesk.shared.draft?.bcc = bcc }
            if let subject = request["subject"] as? String { MailDesk.shared.draft?.subject = subject }
            if let body = request["body"] as? String { MailDesk.shared.draft?.write(body) }
            MailDesk.shared.save()
        case "words":
            // Words of the draft chosen as a drag in them chooses them: by
            // their text, or all of them; the keyboard in them.
            guard let words = MailDesk.shared.words else { break }
            let text = words.string as NSString, value = request["value"] as? String ?? ""
            let found = value.isEmpty ? NSRange(location: 0, length: text.length) : text.range(of: value)
            guard found.location != NSNotFound else { break }
            words.window?.makeFirstResponder(words)
            words.setSelectedRange(found)
        case "caret":
            // The caret at the end of the draft's words, the keyboard in them.
            guard let words = MailDesk.shared.words else { break }
            words.window?.makeFirstResponder(words)
            words.setSelectedRange(NSRange(location: (words.string as NSString).length, length: 0))
        case "typewords":
            // Words typed where the caret is, as the keyboard types them.
            MailDesk.shared.words?.insertText(request["value"] as? String ?? "", replacementRange: MailDesk.shared.words?.selectedRange() ?? NSRange())
        case "mark":
            // A mark on what is chosen in the words, as its key or ⌘K puts it.
            if let mark = MailRich.Mark(rawValue: request["value"] as? String ?? "") { MailDesk.shared.mark(mark) }
        case "from": MailDesk.shared.choose(from: request["value"] as? String ?? "")
        case "pastewords":
            // Words pasted into the draft's words as another app leaves
            // them (`html`, and the plain `value`), on a pasteboard of the
            // bench's own, never the person's.
            guard let words = MailDesk.shared.words else { break }
            let board = NSPasteboard(name: NSPasteboard.Name("yab.bench.words"))
            board.clearContents()
            if let html = request["html"] as? String { board.setString(html, forType: .html) }
            if let text = request["value"] as? String { board.setString(text, forType: .string) }
            words.window?.makeFirstResponder(words)
            _ = words.readSelection(from: board, type: .string)
        case "attach":
            // Files given to the draft as a drop or the panel gives them
            // (MailDesk.attach): paths, a line each.
            let paths = (request["value"] as? String ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            MailDesk.shared.attach(paths)
        case "pickwith":
            // What the panel will answer next time it is asked (⇧⌘U, the paperclip).
            MailDesk.shared.picked = (request["value"] as? String ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        case "paste":
            // A picture (a file's bytes) pasted into the draft's words, on
            // a pasteboard of the bench's own, never the person's.
            guard let path = request["value"] as? String, let data = FileManager.default.contents(atPath: path),
                  let window = MailMorph.shared.pane?.window, let root = window.contentView else { break }
            let board = NSPasteboard(name: NSPasteboard.Name("yab.bench.paste"))
            board.clearContents()
            board.setData(data, forType: path.lowercased().hasSuffix(".png") ? .png : .tiff)
            var views: [NSView] = []
            func walk(_ view: NSView) { views.append(view); view.subviews.forEach(walk) }
            walk(root)
            _ = views.compactMap { $0 as? MailWordsView }.first?.take(from: board)
        case "unattach":
            // ⌫ on a chip, by its file's name.
            if let file = MailDesk.shared.draft?.files.first(where: { $0.name == request["value"] as? String }) {
                MailDesk.shared.detach(file.id)
            }
        case "choosefile":
            // A chip clicked, by its file's name.
            MailDesk.shared.chooseDraftChip(MailDesk.shared.draft?.files.first(where: { $0.name == request["value"] as? String })?.id)
        case "select":
            // Words chosen in the open thread, as a drag in it chooses
            // them, for Quick Quote: in a mail's HTML (asked of its
            // page), or in its own words; the keyboard goes there.
            let words = request["value"] as? String ?? ""
            guard let window = MailMorph.shared.pane?.window, let root = window.contentView, !words.isEmpty else { break }
            var views: [NSView] = []
            func walk(_ view: NSView) { views.append(view); view.subviews.forEach(walk) }
            walk(root)
            let quoted = (try? JSONSerialization.data(withJSONObject: [words])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            let pick = """
            (function(w){const t=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let n;\
            while((n=t.nextNode())){const i=n.data.indexOf(w);if(i>=0){const r=document.createRange();r.setStart(n,i);r.setEnd(n,i+w.length);\
            const s=getSelection();s.removeAllRanges();s.addRange(r);return true}}return false})(\(quoted)[0])
            """
            let front = Set(MailDesk.shared.messages.map(\.id))
            for case let page as MailBodyView in views where front.contains(page.message) {
                page.evaluateJavaScript(pick) { found, _ in if found as? Bool == true { window.makeFirstResponder(page) } }
            }
            for view in views where !(view is NSTextView) && !(view is WKWebView) {
                guard let value = view.accessibilityValue() as? String, let found = value.range(of: words) else { continue }
                window.makeFirstResponder(view)
                view.setAccessibilitySelectedTextRange(NSRange(found, in: value))
                break
            }
        case "search":
            // The words taken from the search, as ↩ on its first row.
            MailSearch.shared.apply(words: request["value"] as? String ?? "", who: MailDesk.shared.who)
        case "fresh": MailDesk.shared.takeFresh()
        // The keys a thread takes, for the morph's tests (MailMorph).
        case "back": MailDesk.shared.back()
        case "next": MailDesk.shared.step(request["value"] as? Int ?? 1)
        case "close": MailDesk.shared.closeDraft()
        case "move": MailDesk.shared.move(request["value"] as? Int ?? 1)
        case "press":
            // A key as the keyboard sends it, through the app's own
            // monitor and menus: ⌘Z mail's or the words'.
            guard Store.testing, let window = Links.window, let key = (request["value"] as? String)?.first else { break }
            let flags: NSEvent.ModifierFlags = request["command"] as? Bool == true ? .command : []
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: String(key),
                                                charactersIgnoringModifiers: String(key), isARepeat: false, keyCode: Bench.keyCode(for: key)) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        case "undo": MailDesk.shared.undoLast()
        // A mailto: link from another app, as macOS hands it over once Yab is the mail app.
        case "mailtoapp": if let url = URL(string: request["value"] as? String ?? "") { Links.takeMail(url) }
        // An invitation's card answered, as A, M, N or its buttons do (MailCalendar).
        case "answer":
            let answers: [String: MailInvite.Answer] = ["accept": .accepted, "maybe": .tentative, "decline": .declined]
            if let answer = answers[request["value"] as? String ?? ""] { MailDesk.shared.answer(answer, message: request["message"] as? String) }
        // ⇧⌘A in a draft: the field's rows the free slots.
        case "slots": MailDesk.shared.offerSlots()
        // A date in a mail made an event (MailEvents): ⌘K's New Event, •••, esc, ↩.
        case "event":
            switch request["value"] as? String ?? "open" {
            case "edit": MailEvents.shared.edit()
            case "close": MailEvents.shared.close()
            case "add": MailEvents.shared.add()
            case "mac": MailEvents.forced = .mac
            case "ask": MailEvents.forced = .ask
            case "denied": MailEvents.forced = .denied
            default: MailEvents.shared.newEvent()
            }
        // Settings › Mail's Calendar, as its rows set it: hours in minutes, a slot's length, the booking link.
        case "calendar":
            for key in ["start", "end", "length"] {
                if let minutes = request[key] as? Int { Store.settings.set(minutes, forKey: "mail.slots." + key) }
            }
            if let link = request["booking"] as? String { Store.settings.set(link, forKey: "mail.booking") }
            MailSlots.kept = nil
        // The corner's button pressed (the spam notice's Also Block).
        case "toast": browser.toaster.undone()
        case "seq":
            // Keys one after another through the app as the keyboard
            // sends them, `gap` seconds apart; with `aloft`, each after
            // the first as soon as a flight is up (`gap` at most), as a
            // key a busy Mac takes longer than the gap over would
            // otherwise come before the flight it is about. Whether a
            // flight was up as each came, and the screen `after` seconds
            // after the last (check.py's speed: input never waits for
            // motion).
            guard Store.testing, Links.window != nil else { break }
            let keys = (request["value"] as? String ?? "").split(separator: ",").map(String.init)
            MailSeq.log = []
            MailSeq.after = [:]
            MailSeq.press(keys, at: 0, gap: request["gap"] as? Double ?? 0.08, aloft: request["aloft"] as? Bool == true,
                          after: request["after"] as? Double ?? 0.05)
        case "wake": MailDesk.shared.wake()
        case "snooze": MailDesk.shared.snooze(at: Date().addingTimeInterval((request["value"] as? Double) ?? 3600), why: "Later")
        // ⇧⌘H's time taken: seconds on mail's clock, or none (the draft's, or the thread's).
        case "remind": MailDesk.shared.remindNoReply(at: (request["value"] as? Double).map { MailClock.now.addingTimeInterval($0) })
        // Slow motion in a test world: every length of mail's motion times this.
        case "slow": if Store.testing { MailMorph.pace = max(0.1, request["value"] as? Double ?? 1) }
        // Settings › Mail's Animations, as its switch turns it.
        case "animations": browser.prefs.mailAnimations = request["value"] as? Bool ?? true
        case "unfold": MailDesk.shared.unfolded = Set(MailDesk.shared.messages.map(\.id))
        // A file's chip under a mail, by its name, chosen as a click
        // chooses it; then what its keys do (MailFileChips). A test
        // world's only: nothing else opens or saves a person's files.
        case "chip" where Store.testing:
            let name = request["value"] as? String ?? ""
            if let message = MailDesk.shared.messages.first(where: { $0.files.contains { $0.name == name } }),
               let file = message.files.first(where: { $0.name == name }) {
                MailDesk.shared.choose(MailDesk.Chip(message: message.id, part: file.part))
            }
        case "look" where Store.testing: MailDesk.shared.look()
        case "openfile" where Store.testing: MailDesk.shared.openFile()
        case "savefile" where Store.testing: MailDesk.shared.saveFile()
        case "openfirst" where Store.testing: MailDesk.shared.openFirst()
        case "link":
            // The first link in the last mail, followed as a click would.
            if let html = MailDesk.shared.messages.last?.html,
               let match = html.range(of: "href=\"(https?://[^\"]+)\"", options: .regularExpression),
               let url = URL(string: String(html[match]).replacingOccurrences(of: "href=\"", with: "").replacingOccurrences(of: "\"", with: "")) {
                MailDesk.shared.follow(url)
            }
        case "open":
            let parts = (request["value"] as? String ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                var url = URLComponents(string: "yab://mail")!
                url.fragment = "thread=" + parts[0] + "|" + parts[1]
                browser.enterMail(url.url)
            }
        // Snippets (MailSnippets): made and changed as Settings › Mail's
        // editor and its name cell do, put in as ⌘; and ↩ do, saved as
        // ⌘K's Save as Snippet does.
        case "snippetadd":
            let paths = (request["files"] as? String ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            MailSnippets.shared.add(name: request["value"] as? String ?? "", body: request["body"] as? String ?? "",
                                    to: request["to"] as? String ?? "", cc: request["cc"] as? String ?? "",
                                    bcc: request["bcc"] as? String ?? "", subject: request["subject"] as? String ?? "", files: paths)
        case "snippetedit":
            if var snippet = MailSnippets.shared.named(request["value"] as? String ?? "") {
                if let body = request["body"] as? String { snippet.body = body }
                if let name = request["name"] as? String { snippet.name = name }
                for (key, path) in [("to", \MailSnippet.to), ("cc", \MailSnippet.cc), ("bcc", \MailSnippet.bcc), ("subject", \MailSnippet.subject)] {
                    if let value = request[key] as? String { snippet[keyPath: path] = value }
                }
                MailSnippets.shared.change(snippet)
            }
        case "snippetremove":
            if let snippet = MailSnippets.shared.named(request["value"] as? String ?? "") { MailSnippets.shared.remove(snippet.id) }
        case "snippet":
            if let snippet = MailSnippets.shared.named(request["value"] as? String ?? "") { MailDesk.shared.insert(snippet) }
        case "savesnippet": MailDesk.shared.saveSnippet(named: request["value"] as? String ?? "")
        case "wordsundo":
            // Edit › Undo (or Redo) in the words, as ⌘Z sends it there from a key window.
            let undo = MailDesk.shared.wordsView()?.undoManager
            if request["redo"] as? Bool == true { undo?.redo() } else { undo?.undo() }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ((request["wait"] as? Double) ?? 0.4)) {
            let desk = MailDesk.shared
            let screen = desk.screen == .list ? "list" : desk.screen == .thread ? "thread" : "compose"
            var state: [String: Any] = ["view": screen, "subjects": desk.rows.map(\.subject), "sel": desk.sel, "open": desk.open?.thread ?? "",
                                        "openSubject": desk.open?.subject ?? "", "fresh": desk.fresh, "messages": desk.messages.count]
            if let card = MailEvents.shared.card {
                state["event"] = ["title": card.event.title, "when": card.event.when(locale: AppDates.locale), "with": card.event.with ?? "", "editing": card.editing,
                                  "anchored": card.anchor != nil, "message": card.message]
            }
            state["dates"] = desk.messages.map { MailEvents.shared.dated($0, html: MailEvents.showsHTML($0)).found.count }
            state["html"] = desk.messages.last?.html ?? ""
            state["text"] = desk.messages.last?.text ?? ""
            state["ahead"] = desk.ready.map(\.text)
            state["readyBy"] = desk.ready.map(\.by)
            state["pick"] = desk.pick
            state["writtenBy"] = desk.writtenBy
            state["asking"] = desk.asking ?? NSNull()
            state["writing"] = desk.writing
            state["touched"] = desk.touched
            state["person"] = desk.person?.name ?? ""
            state["personAddress"] = desk.person?.address ?? ""
            state["draftTo"] = desk.draft?.to ?? ""
            // A new mail over a page, from a mailto: link (MailtoPeek.swift).
            state["outside"] = desk.outside
            state["mailtoUp"] = browser.mailtoFrom != nil
            // A thread over a page, from a row of Now (MailThreadPeek.swift).
            state["threadPeekUp"] = browser.threadPeek != nil
            state["toast"] = browser.toaster.shown ? browser.toaster.said.head : ""
            state["draftBody"] = desk.draft?.body ?? ""
            state["drafting"] = desk.draft != nil
            state["why"] = desk.why
            // The open thread's invitations as their cards say them (MailCalendar).
            state["invites"] = desk.invites.map { card -> [String: Any] in
                let at = (card.at.start, card.at.end)
                return ["message": card.message, "uid": card.invite.uid, "title": card.invite.title, "method": card.invite.method,
                        "sequence": card.invite.sequence, "when": card.invite.when(at), "theirs": card.invite.theirs(at) ?? "",
                        "organizer": card.invite.organizer?.address ?? "", "answer": card.answer?.rawValue ?? "", "sending": card.sending,
                        "before": card.before?.rawValue ?? "", "change": card.change ?? "", "answerable": card.answerable,
                        "clashes": card.clashes.map { $0.map(\.title) } ?? NSNull(), "clash": MailInvites.said(card.clashes ?? []) ?? "",
                        "canceled": card.invite.canceled, "rule": card.invite.rule?.said ?? "", "place": card.invite.placeSaid]
            }
            state["fieldTyped"] = browser.typed
            // The field's Mail rows as they stand, by id (the slots, the commands).
            state["fieldRows"] = browser.query.offers.compactMap { offer -> [String: Any]? in
                guard case .page(let what) = offer.kind, what.hasPrefix("mail:"), let row = Browser.mailRows[String(what.dropFirst(5))] else { return nil }
                return ["id": String(what.dropFirst(5)), "title": offer.key, "detail": offer.title, "end": row.end, "section": row.section,
                        "quiet": row.quiet]
            }
            // The row ↩ takes now: chosen, pointed at, or the field's first.
            state["fieldCurrent"] = browser.query.current.flatMap { at -> String? in
                guard browser.query.offers.indices.contains(at), case .page(let what) = browser.query.offers[at].kind else { return nil }
                return what.hasPrefix("mail:") ? String(what.dropFirst(5)) : nil
            } ?? ""
            state["rowsSaid"] = desk.rows.map { $0.subject + " · " + $0.when }
            // Each row's line, as the list draws it after its subject; a reminder still waiting, as its end says it.
            state["rowLines"] = desk.rows.map { $0.subject + " · " + $0.line }
            state["rowPreviews"] = Dictionary(desk.rows.map { ($0.id, $0.line) }, uniquingKeysWith: { first, _ in first })
            state["rowReminds"] = desk.rows.filter { !$0.remind.isEmpty }.map { $0.subject + " · " + $0.remind }
            state["unread"] = desk.rows.filter(\.unread).map(\.subject)
            // Rows picked (X, ⇧J, ⌘A), what the list is narrowed to (⇧U),
            // the starred rows, and G waiting for its key.
            state["picked"] = desk.rows.filter { desk.selection.contains($0.id) }.map(\.subject)
            state["only"] = desk.only?.rawValue ?? ""
            state["starred"] = desk.rows.filter(\.starred).map(\.subject)
            state["openStarred"] = desk.open?.starred ?? false
            state["searching"] = desk.searching
            state["link"] = desk.lastLink?.absoluteString ?? ""
            state["inMail"] = browser.inMail
            state["sidebar"] = browser.prefs.sidebar
            state["turned"] = MailSpaceState.shared.turnedSidebar
            state["split"] = list.split
            state["account"] = list.account
            state["apart"] = MailCenter.shared.apart.sorted()
            state["together"] = MailCenter.shared.together
            state["accountName"] = MailAccountMark.name(list.account, accounts: MailCenter.shared.accounts)
            state["needsByAccount"] = list.needs
            state["counted"] = MailCenter.shared.counted
            state["rowAccounts"] = desk.rows.map(\.account)
            state["choosing"] = list.choosing
            state["chooserUp"] = MailAccountFloat.shared.up
            state["counts"] = list.counts
            // Mail after Town: the offers, the day's line, the card over
            // Needs you, the person's Who, the split's routine.
            state["offers"] = list.offers.map { $0.id + " · " + $0.words.before + $0.words.name + $0.words.after }
            state["today"] = MailList.todayLine(list.today)
            state["sortedCard"] = list.sorted != nil
            state["personWho"] = desk.person?.card?.who ?? ""
            state["promisedLit"] = desk.messages.flatMap(\.promised)
            state["whoSource"] = desk.person?.card?.source ?? ""
            state["openBetween"] = desk.person?.open.map { $0.words + " · " + $0.when } ?? []
            state["routine"] = Routines.shared.onMail(list.split).map { $0.prompt + " · " + ($0.may ?? "") } ?? ""
            state["noReady"] = desk.rows.filter(\.noReady).map(\.subject)
            state["agentReady"] = desk.rows.filter(\.agentReady).map(\.subject)
            state["flashed"] = MailList.shared.flashed
            state["kept"] = list.kept.map { $0.title + " · " + $0.said }
            state["keptSaid"] = list.keptSaid
            state["lists"] = list.yours.map(\.title)
            // The column as it stands (its order, empty splits hidden),
            // every split as kept, and what Skip the inbox did today.
            state["column"] = list.column.map { $0.id }
            state["columnSaid"] = list.column.map { $0.title + ($0.note.isEmpty ? $0.count > 0 ? " \($0.count)" : "" : " · " + $0.note) }
            state["splitOrder"] = list.order
            state["splits"] = list.splits.map { ["id": $0.id, "title": $0.title, "on": $0.on, "mode": $0.mode.rawValue, "notify": $0.notifies,
                                                 "q": $0.q, "rules": $0.rules.map { $0.said.kind + " " + $0.said.value }] as [String: Any] }
            state["hideEmpty"] = list.hideEmpty
            state["skippedToday"] = list.skippedToday
            let archived = MailCenter.shared.archivedToday()
            state["archivedLine"] = archived.count > 0 ? Noticing.archived(archived.count, names: archived.splits.map { MailList.name($0) }).title : ""
            state["pill"] = MailFootPill.items(desk).map(\.words)
            // A filter's menu as it stands: which, the words in it, its rows.
            let menu = MailFilterMenu.shared
            state["filterOpen"] = menu.open.map { MailFilterMenu.anchor($0) } ?? ""
            state["filterTyped"] = menu.typed
            state["filterRowCounts"] = Dictionary(uniqueKeysWithValues: menu.rows().compactMap { row -> (String, [String: Int])? in
                guard let line = row.lines.first, let base = menu.split?.q,
                      let count = MailFilterCounts.shared.count(line, base: base, account: list.account) else { return nil }
                return (row.id, ["all": count.all, "added": count.added])
            })
            state["filterRows"] = menu.rows().map { ($0.ticked == true ? "[x] " : $0.ticked == false ? "[ ] " : "") + $0.title }
            state["library"] = browser.query.place == .mail && browser.query.stock.mail?.mode == .library
            state["libraryChosen"] = browser.mailLibraryChosen ?? ""
            state["libraryCounts"] = MailSplitLibrary.shared.previews.mapValues(\.count)
            state["columnView"] = list.view
            state["working"] = Array(list.working.keys)
            state["shown"] = list.shown ?? ""
            state["tabs"] = browser.tabs.map { ["id": $0.id.uuidString, "address": $0.address?.absoluteString ?? "", "title": $0.title, "pin": $0.pin != nil] }
            state["active"] = browser.active?.address?.absoluteString ?? ""
            state["activeID"] = browser.active?.id.uuidString ?? ""
            // The space's tabs the column lists under its lists (MailTabRows).
            state["mailTabs"] = browser.mailTabs.map { ($0.pending ?? $0.address)?.absoluteString ?? "" }
            state["paging"] = list.paging
            state["activeTitle"] = browser.active?.title ?? ""
            state["peek"] = browser.peeking.map { ($0.pending ?? $0.address)?.absoluteString ?? "loading" } ?? ""
            // Every peek's panels in the window, kept ones hidden apart: more
            // than one shown is peeks stacked.
            var panels: [String] = []
            func walkPeeks(_ view: NSView) {
                if let peek = view as? PeekView { panels.append(contentsOf: peek.panelsSaid) }
                view.subviews.forEach(walkPeeks)
            }
            if let content = Links.window?.contentView { walkPeeks(content) }
            state["peekPanels"] = panels
            state["space"] = browser.space.name
            // Mail held still (Reduce Motion, Animations off), and a flight up over the window now.
            state["still"] = MailDesk.still
            state["animations"] = MailDesk.animations
            state["flying"] = MailMorph.shared.aloft
            state["searchGrew"] = MailSearch.shared.grew
            // Animations off (not Reduce Motion): not even a fade.
            state["instant"] = MailDesk.instant
            state["seq"] = MailSeq.log
            state["seqAfter"] = MailSeq.after
            // The thread after the one in front: its mail here whole before
            // J (MailSync.prefetch), and the threads being fetched ahead now.
            state["nextLocal"] = desk.nextLocal
            state["fetchingAhead"] = desk.fetchingAhead
            // Letters made ahead of J and K, unseen (MailDesk.ahead).
            state["lettersAhead"] = desk.ahead.compactMap { $0.open?.subject }
            let returning: String = MailDesk.shared.returning.sorted().joined(separator: ",")
            // Typed and built a few at a time: as one literal, Swift 6.3
            // (Xcode 26) gives up type-checking it.
            var morph: [String: Any] = ["flights": MailMorph.shared.flight, "said": MailMorph.shared.said,
                                        "flying": Array(MailDesk.shared.flying),
                                        "took_ms": MailMorph.shared.took, "start_ms": MailMorph.shared.started]
            morph["heading"] = MailMorph.shared.window("heading").map { "\($0)" } ?? ""
            morph["parts"] = MailMorph.shared.parts.keys.filter { !$0.hasPrefix("row:") }.sorted()
            let rectIDs = ["list:title", "list:count", "heading", "gline", "first", "last", "crumb:name", "crumb:of"]
            let rects: [(String, String)] = rectIDs.compactMap { id in MailMorph.shared.window(id).map { (id, "\($0)") } }
            morph["rects"] = Dictionary(uniqueKeysWithValues: rects)
            morph["move"] = "\(MailDesk.shared.move)"
            morph["returning"] = returning
            morph["undo"] = MailDesk.shared.undoable
            morph["toast"] = browser.toaster.shown ? browser.toaster.words : ""
            let selRow: String? = desk.rows.indices.contains(desk.sel) ? desk.rows[desk.sel].id : nil
            morph["sel_rect"] = selRow.flatMap { MailMorph.shared.window("row:" + $0) }.map { "\($0)" } ?? ""
            morph["list_place"] = desk.listPlace.viewID(type: String.self) ?? ""
            morph["pane_rect"] = MailMorph.shared.pane.map { "\($0.convert($0.bounds, to: nil))" } ?? ""
            state["morph"] = morph
            let search = MailSearch.shared
            state["found"] = search.hits.compactMap { if case .person(let contact) = $0 { return contact.said } else { return nil } }
            state["hits"] = search.hits.map(\.id)
            state["hitLit"] = search.lit
            state["typed"] = search.typed
            state["personLit"] = search.personLit
            state["recents"] = search.recents.map(\.q)
            state["query"] = desk.query
            // A search's rows Gmail found (Row.gmail), how many it holds in all, and Gmail still asked.
            state["gmail"] = desk.rows.filter(\.gmail).map(\.subject)
            // The column's labels as it shows them, and a list beyond the
            // inbox's with Gmail: asked now, more there than came, trouble.
            let labels = MailLabels.shared
            state["columnLabels"] = labels.rows.map { ["name": $0.name, "leaf": $0.leaf, "depth": $0.depth, "unread": $0.unread,
                                                        "parent": $0.parent, "open": $0.open] as [String: Any] }
            state["labelNames"] = labels.names
            state["labelsFolded"] = labels.folded
            state["labelsHidden"] = labels.hidden
            state["labelNaming"] = labels.naming ?? ""
            state["labelMaking"] = labels.making ?? "-"
            state["labelTaken"] = labels.taken
            state["labelToast"] = browser.toaster.shown ? browser.toaster.words : ""
            let gmail = MailServerSearch.shared.view(list.split, account: list.account)
            state["viewGmail"] = ["asking": gmail.asking, "more": gmail.more, "trouble": gmail.trouble ?? ""] as [String: Any]
            state["total"] = desk.total
            state["gmailAsking"] = desk.searchAsked.map { MailServerSearch.shared.asking($0, accounts: MailCenter.shared.accounts) } ?? false
            state["who"] = desk.who?.title ?? ""
            state["crowd"] = desk.crowd.map(\.said)
            state["newer"] = desk.newer?.from ?? ""
            state["focus"] = desk.focus ?? -1
            state["quoted"] = desk.messages.filter { $0.quote != nil }.count
            state["replyTo"] = desk.replyTo.map(\.address)
            state["readyAll"] = desk.readyAll
            state["crowded"] = desk.crowded
            state["labels"] = desk.ready.map(\.label)
            state["draftCc"] = desk.draft?.cc ?? ""
            state["draftBcc"] = desk.draft?.bcc ?? ""
            state["draftSubject"] = desk.draft?.subject ?? ""
            state["draftQuote"] = desk.draft?.quote ?? ""
            state["draftForward"] = desk.draft?.forward ?? false
            // Its words' marks (MailRich), where it goes from and its signature (MailSendAs).
            state["draftHTML"] = desk.draft?.html ?? ""
            state["draftFrom"] = desk.sending
            state["senders"] = desk.senders.map(\.address)
            state["draftSigned"] = desk.draft?.signed ?? false
            state["draftSignature"] = desk.draft.flatMap(MailDesk.signature(of:))?.text ?? ""
            // Its pictures as the draft shows them: each by its file's name, loaded or not; and those it can't show.
            let pieces = desk.draft.flatMap(MailDesk.signature(of:))?.pieces ?? []
            state["draftSignaturePictures"] = pieces.compactMap { piece -> String? in
                guard case .picture(let url, _, _) = piece else { return nil }
                return url.lastPathComponent + (MailSignaturePictures.shared.images[url] == nil ? "" : " · loaded")
            }
            state["draftSignatureUnshown"] = pieces.filter { $0 == .unshown }.count
            state["wordsShown"] = desk.words?.string ?? ""
            // The words' view as tall as its words need: lines typed grow it, though a key redraws nothing else.
            state["wordsTall"] = desk.words.map { Double($0.frame.height) } ?? 0
            state["wordsFit"] = desk.words.map { abs($0.frame.height - MailWords.tall($0)) < 1 } ?? false
            state["wordsFocused"] = desk.words.map { $0.window?.firstResponder === $0 } ?? false
            state["draftParts"] = desk.parts.map { "\($0)" }.sorted()
            // The draft's reminder if nobody answers, as its foot says it.
            state["draftRemind"] = desk.draft?.remind.map { MailFollowups.line($0) } ?? ""
            state["readyRemind"] = desk.ready.map { $0.remind.map { MailFollowups.line($0) } ?? "" }
            // Its files as their chips say them, the one chosen, and the
            // copies kept beside the store.
            state["draftFiles"] = (desk.draft?.files ?? []).map { $0.name + " · " + $0.said }
            state["draftOriginals"] = (desk.draft?.files ?? []).filter(\.original).map(\.name)
            state["draftChip"] = desk.draft?.files.first { $0.id == desk.draftChip }?.name ?? ""
            // Snippets: each "name · uses", the places left to fill in the
            // draft and the line over Send that says them.
            state["snippets"] = MailSnippets.shared.ordered.map { "\($0.name) · \($0.uses)" }
            state["snippetWords"] = Dictionary(MailSnippets.shared.all.map { ($0.name, $0.body) }) { first, _ in first }
            state["snippetIDs"] = Dictionary(MailSnippets.shared.all.map { ($0.name, $0.id) }) { first, _ in first }
            state["snippetKept"] = Dictionary(MailSnippets.shared.all.map { snippet in
                (snippet.name, ["subject": snippet.subject, "cc": snippet.cc, "files": snippet.files.map(\.name)] as [String: Any])
            }) { first, _ in first }
            // The list under the caret after ";" (MailSnippetPicker): its rows, the lit one.
            state["picker"] = MailSnippetPicker.shared.call?.rows.map(\.name) ?? []
            state["pickerLit"] = MailSnippetPicker.shared.call.map { $0.rows[$0.lit].name } ?? ""
            state["holes"] = desk.holes
            state["holeLine"] = MailSnippets.line(desk.holes) ?? ""
            state["wordsChosen"] = desk.wordsView().map { view in (view.string as NSString).substring(with: view.selectedRange()) } ?? ""
            state["originals"] = desk.originalsCommand ?? ""
            if let draft = desk.draft, let store = MailCenter.shared.engines[draft.account]?.store {
                state["draftCopies"] = draft.files.compactMap { MailAttach.place($0, draft: draft.id, store: store) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
                state["draftFolder"] = MailAttach.folder(for: store, draft: draft.id)?.path ?? ""
            }
            state["chosen"] = (MailMorph.shared.pane?.window?.firstResponder as? NSView)?.accessibilitySelectedText() ?? ""
            state["order"] = browser.turnOrder.map(\.name)
            state["mailIcon"] = Space.mail.icon
            state["mailSwatch"] = Space.mail.paint?.swatch ?? ""
            state["worn"] = SpacePaint(browser.prefs).swatch
            state["command"] = Command.mail.available(in: browser) ? Command.mail.title(in: browser) : ""
            state["usesSpaces"] = browser.prefs.usesSpaces
            state["listDraft"] = list.draft != nil
            state["ghost"] = desk.ghost
            state["making"] = list.making
            if let saved = list.split == "draft" ? list.draft : list.split(list.split) {
                state["listTitle"] = saved.title
                state["listIcon"] = saved.icon ?? ""
                state["listWhy"] = saved.why ?? ""
                state["listRules"] = saved.rules.map { $0.kind + " " + $0.value }
                state["listPages"] = (saved.pages ?? []).map(\.title)
                state["listGroup"] = saved.group ?? ""
                state["summary"] = list.summaries[saved.id]?.text ?? ""
                state["headings"] = desk.rows.indices.compactMap { MailListHeadings.at(desk.rows, $0, saved.group) }
            }
            // Cleanup: a bulk act on its way to Gmail, who is kept out, and
            // the Bulk Actions log, each "said · threads · taken back".
            state["going"] = MailGoing.shared.line ?? ""
            state["inbox"] = MailCenter.shared.engines.values.reduce(0) { $0 + $1.store.inboxThreads().count }
            state["blocked"] = MailCenter.shared.engines.values.flatMap { $0.store.blocked().map(\.who) }.sorted()
            state["bulks"] = MailCenter.shared.engines.values.flatMap { engine in
                engine.store.bulks(since: Date().addingTimeInterval(-MailOps.bulkKept)).map { "\($0.said) · \($0.threads) · \($0.back == nil ? "kept" : "back")" }
            }
            state["pinWanted"] = MailCenter.shared.pinWanted
            state["pinHere"] = MailCenter.hasPin(browser)
            state["entries"] = MailThreadEntries.kinds(desk)
            // Files: rows with a clip, the open thread's chips (name ·
            // size), the one chosen, Quick Look, what was opened and saved.
            state["clips"] = desk.rows.filter(\.attached).map(\.subject)
            state["chips"] = desk.messages.flatMap { $0.files.map { $0.name + " · " + $0.said } }
            state["chipBytes"] = desk.messages.flatMap { $0.files.map(\.size) }
            let chosen = desk.chip.flatMap { chip in desk.messages.first { $0.id == chip.message }?.files.first { $0.part == chip.part } }
            state["chip"] = chosen?.name ?? ""
            state["looking"] = MailLook.shared.item?.lastPathComponent ?? ""
            // Plain keys nothing took, kept from the page under mail (ContentView.mailKeeps).
            state["keysKept"] = ContentView.mailKept
            state["lookVisible"] = MailLook.shared.visible
            state["getting"] = desk.getting.count
            state["failedFiles"] = desk.failed.count
            state["opened"] = desk.opened?.path ?? ""
            state["saved"] = desk.saved?.path ?? ""
            state["served"] = MailCid.served
            state["loot"] = browser.loot.kept.first?.path ?? ""
            // Read statuses (MailReads): the line under each mail of the
            // open thread ("" for none), and each row's that says one.
            state["reads"] = desk.messages.map { $0.reads.map { MailReads.line($0) } ?? "" }
            state["rowReads"] = desk.rows.filter { !$0.opened.isEmpty }.map { $0.subject + ": " + $0.opened }
            answer(state)
        }
    }
}
