import Foundation
import os
#if canImport(SyncKit)
import SyncKit
#endif

/// Sync's records in the app's shapes, and the app's tabs as addresses sync
/// keeps. Pure functions: what a row looks like on the iPhone is decided
/// here, the bridge only says when.
enum SyncMapping {
    // MARK: - addresses

    /// What the field shows of an address: no scheme, no www., no slash at
    /// the end. "https://www.figma.com/file/x/" is "figma.com/file/x".
    static func address(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if s.lowercased().hasPrefix("www.") { s = String(s.dropFirst(4)) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The address sync keeps for what the field shows: a scheme of its own
    /// kept, a local server's http, everything else https.
    static func fullURL(_ address: String) -> String {
        if address.contains("://") || address.hasPrefix("about:") || address.hasPrefix("data:") { return address }
        let host = address.split(separator: "/").first.map(String.init) ?? address
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        let local = ["localhost", "127.0.0.1", "[::1]"].contains(bare) || bare.hasSuffix(".localhost") || bare.hasSuffix(".local")
        return (local ? "http://" : "https://") + address
    }

    static func wireURL(_ tab: Tab, fixturesEnabled: Bool) -> String {
        if fixturesEnabled { return fullURL(tab.address) }
        return tab.navigationURL?.absoluteString ?? "about:blank"
    }

    /// The host of an address, without www. and the port.
    static func host(_ url: String) -> String {
        let rest = address(url)
        let host = rest.split(separator: "/").first.map(String.init) ?? rest
        if host.hasPrefix("[") { return host.split(separator: "]").first.map { String($0) + "]" } ?? host }
        return (host.split(separator: ":").first.map(String.init) ?? host).lowercased()
    }

    /// A local server's port, as the plate writes it after the site: ":5173".
    static func port(_ url: String) -> String? {
        let rest = address(url)
        let host = rest.split(separator: "/").first.map(String.init) ?? rest
        guard !host.hasPrefix("["), let colon = host.lastIndex(of: ":") else { return nil }
        let digits = host[host.index(after: colon)...]
        return digits.isEmpty || !digits.allSatisfy(\.isNumber) ? nil : ":" + digits
    }

    /// What the plate says for a site it has no name for: the name before
    /// the domain's end, the way people say it.
    static func siteName(_ host: String) -> String {
        if ["localhost", "127.0.0.1", "[::1]"].contains(host) { return "localhost" }
        if let known = knownSites[host] { return known }
        let labels = host.split(separator: ".").map(String.init)
        let ends: Set<String> = ["com", "org", "net", "io", "app", "dev", "co", "so", "events", "se", "pt", "uk", "de", "example"]
        let name = labels.count > 1 ? (labels.dropLast().last { !ends.contains($0) } ?? labels[0]) : (labels.first ?? host)
        if let known = knownSites[name] { return known }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Names a site writes its own way.
    static let knownSites: [String: String] = [
        "github": "GitHub", "youtube": "YouTube", "ycombinator": "Hacker News", "news.ycombinator.com": "Hacker News",
        "nngroup": "NN/g", "theverge": "The Verge", "linkedin": "LinkedIn", "paulgraham": "Paul Graham",
        "mail.google.com": "Gmail", "docs.google.com": "Google Docs", "wikipedia": "Wikipedia", "timeout": "Time Out",
    ]

    // MARK: - test pages

    /// A page the app carries for an address or title (Resources/Pages,
    /// pages.json): test worlds show the drawn page a Mac's tab stands for.
    struct Fixture: Decodable, Equatable, Sendable {
        let stem: String
        let fav: String
        let title: String
        let site: String
        let url: String
        let dark: Bool?
    }

    static let fixtures: [Fixture] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Pages/pages.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Fixture].self, from: data)) ?? []
    }()

    /// The fixture of a tab: by its title first (the pages say their own),
    /// then by address.
    static func fixture(title: String, url: String, in list: [Fixture] = fixtures) -> Fixture? {
        if let hit = list.first(where: { $0.title == title }) { return hit }
        let address = address(url).lowercased()
        guard !address.isEmpty else { return nil }
        return list.first { SyncMapping.address($0.url).lowercased() == address }
    }

    // MARK: - tabs and spaces

    /// A synced tab as a row. A tab the iPhone already shows keeps its look
    /// (icon, page, dark) while its address stays; its title is sync's.
    static func tab(_ synced: SyncTab, id: String, old: Tab?, fixtures list: [Fixture] = fixtures,
                    fixturesEnabled: Bool = true) -> Tab {
        let address = address(synced.url)
        let title = synced.name ?? (synced.title.isEmpty ? address : synced.title)
        let same = fixturesEnabled ? SyncMapping.address(fullURL(old?.address ?? "")).lowercased() == address.lowercased()
            : old?.url == synced.url
        if var old, same {
            old.id = id
            old.title = title
            old.pageTitle = synced.title
            old.name = synced.name
            old.customMark = synced.customMark
            if !fixturesEnabled { old.url = synced.url; old.page = nil }
            return old
        }
        let host = host(synced.url)
        let page = fixturesEnabled ? fixture(title: synced.title, url: synced.url, in: list) : nil
        var tab = Tab(id: id, title: title, site: page?.site ?? siteName(host), icon: page?.fav ?? host, url: fixturesEnabled ? address : synced.url,
                   page: page?.stem, host: host, port: port(synced.url), dark: page?.dark ?? false, onMac: old?.onMac ?? false)
        tab.pageTitle = synced.title
        tab.name = synced.name
        tab.customMark = synced.customMark
        return tab
    }

    /// The kept tabs in the order the iPhone shows them: a folder's tabs
    /// together, where its first one stands.
    static func keptOrder(_ row: SyncRow) -> [String] {
        SyncKeptTree.make(row).flatMap(\.tabs).map(\.id)
    }

    /// The wash of a space with no color of its own: the Mac's sidebar
    /// gray-blue, Work's in Mira's world.
    static let plainTint = RGB(226, 233, 244)

    /// A Mac space's color as the iPhone's wash: its own color, mostly white,
    /// the way the Mac's sidebar wears it.
    static func tint(_ paint: SyncPaint?) -> RGB? {
        guard let paint, let rgb = rgb(hex: paint.color) else { return nil }
        func mix(_ c: Int) -> Int { Int((Double(c) * 0.18 + 255 * 0.82).rounded()) }
        return RGB(mix(rgb.r), mix(rgb.g), mix(rgb.b))
    }

    static func rgb(hex: String) -> RGB? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return RGB((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    /// A space from sync's row, keeping what is the iPhone's own: which tab
    /// it shows, which folders it folded, its private tabs (never synced),
    /// whether the pins were opened for the day. `local` names a synced id
    /// the way the app knows it.
    static func space(_ synced: SyncSpace, row: SyncRow, old: Space?, local: (String) -> String = { $0 },
                      fixtures list: [Fixture] = fixtures, fixturesEnabled: Bool = true) -> Space {
        let oldTabs = Dictionary((old?.allTabs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func make(_ tab: SyncTab) -> Tab {
            let id = local(tab.id)
            return SyncMapping.tab(tab, id: id, old: oldTabs[id], fixtures: list, fixturesEnabled: fixturesEnabled)
        }
        let pins = row.pins.map(make)
        let oldFolders = Dictionary((old?.folders ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func makeItem(_ node: SyncKeptTree.Node) -> KeptItem {
            switch node {
            case let .tab(tab): return .tab(make(tab))
            case let .folder(folder, children):
                let id = local(folder.id)
                let had = oldFolders[id]
                return .folder(Folder(id: id, name: folder.name ?? "Folder", open: had?.open ?? folder.open ?? true,
                                      items: children.map(makeItem), customMark: folder.customMark, task: had?.task, color: folder.color))
            }
        }
        let kept = SyncKeptTree.make(row).map(makeItem)
        // Private tabs live on this iPhone only, each where it stood among
        // today's: before the row that was under it, else after the one above.
        let today = keepingPrivates(old?.today ?? [], in: row.today.map(make))
        // The Mac's first space signs in where every other does, as on the
        // Mac: a record from an iPhone that offered it its own is not taken.
        let first = SyncCollection.isFirstSpace(synced.id)
        var space = Space(id: local(synced.id), name: synced.name, emoji: SpaceSymbols.emoji(synced.icon),
                          tint: tint(synced.paint) ?? old?.tint ?? plainTint, pins: pins, kept: kept, today: today,
                          current: nil, pinsOpen: old?.pinsOpen ?? false, isPrivate: false,
                          look: synced.paint.flatMap { SpaceLook($0.raw) }, ownSignIns: synced.ownSignIns && !first,
                          signInWith: first ? nil : synced.signInWith.map(local))
        space.current = current(in: space, old: old)
        return space
    }

    /// Today's rows from sync with this iPhone's private tabs put back where
    /// they stood: before the synced row that followed each, else after the
    /// one before it, else at the end. A tab the Mac just opened stays first.
    /// `keep` names other tabs of `old` put back the same way.
    static func keepingPrivates(_ old: [Tab], in synced: [Tab], keep: (Tab) -> Bool = \.isPrivate) -> [Tab] {
        guard old.contains(where: keep) else { return synced }
        var out = synced
        let here = Set(synced.map(\.id))
        for (i, tab) in old.enumerated() where keep(tab) {
            let below = old[(i + 1)...].first { !keep($0) && here.contains($0.id) }
            let above = old[..<i].last { !keep($0) && here.contains($0.id) }
            if let below, let at = out.firstIndex(where: { $0.id == below.id }) {
                out.insert(tab, at: at)
            } else if let above, let at = out.firstIndex(where: { $0.id == above.id }) {
                // After it and after the tabs already put back behind it.
                var j = at + 1
                while j < out.count, !here.contains(out[j].id) { j += 1 }
                out.insert(tab, at: j)
            } else {
                out.append(tab)
            }
        }
        return out
    }

    /// The tab a space shows after a change: the same one while it is there;
    /// gone, the today's tab that took its place. An iPhone showing nothing
    /// keeps showing nothing whatever a Mac does (Space.current never syncs):
    /// a pin or a kept tab never steps forward, and a tab opened on the Mac
    /// waits in the stack. A space first seen here shows its first today's.
    static func current(in space: Space, old: Space?) -> Tab.ID? {
        let ids = space.allTabs.map(\.id)
        guard let old else { return space.today.first?.id }
        guard let current = old.current else { return nil }
        if ids.contains(current) { return current }
        let today = Set(space.today.map(\.id))
        if let i = old.pagingOrder.firstIndex(where: { $0.id == current }) {
            let after = old.pagingOrder.dropFirst(i + 1).map(\.id).first { today.contains($0) }
            let before = old.pagingOrder.prefix(i).reversed().map(\.id).first { today.contains($0) }
            if let next = after ?? before { return next }
        }
        return space.today.first?.id
    }

    // MARK: - chats

    /// A chat that runs on a Mac, with what it said: your words, its
    /// answers, and what each turn did (TurnWork): its thoughts folded, its
    /// subagents at work, once over a line of its steps and sites, and why
    /// the last couldn't finish. Words sent from here that the Mac hasn't
    /// put in the chat yet follow, waiting.
    /// The account's Macs as the wait rows say them (MacWords): a chat's
    /// Mac by its id, and another that is up for "Ask on Mac mini".
    struct Macs {
        var name: (String) -> String?
        var state: (String) -> MacState
        /// Another Mac up that runs this agent (`cli`), not the chat's own.
        var other: (_ device: String, _ cli: String?) -> SyncMac?

        static let none = Macs(name: { _ in nil }, state: { _ in .up }, other: { _, _ in nil })
    }

    static func chat(_ head: SyncChat, items: [SyncChatItem], sends: [SyncSend], macAsleep: Bool, old: Chat?,
                     now: Date = Date(), calendar: Calendar = .current,
                     ownPhone: String? = nil, macs: Macs? = nil) -> Chat {
        var messages: [Message] = []
        var unmatched = sends.filter { $0.chat == head.id && (!$0.text.isEmpty || !$0.files.isEmpty) }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        let agent = head.cli == "codex" ? "ChatGPT" : "Claude"
        let running = head.state == "running"
        let failed = head.state == "failed"
        let turns = TurnWork.turns(items)
        var live: [TurnWork.Subagent] = []
        var failure: TurnWork?
        for (index, turn) in turns.enumerated() {
            let last = index == turns.count - 1
            let asked = turn.first { $0.kind == "asked" && $0.name != "steer" } ?? turn.first { $0.kind == "asked" }
            let report = asked.flatMap { SubagentReport($0.text) }
            let ending = TurnWork.ending(turn, last: last, state: failed ? "failed" : "done")
            var thoughts: [SyncChatItem] = []
            var answered: [Int] = []
            var cards: [ResultCard] = []
            func fold() {
                guard let first = thoughts.first else { return }
                let text = thoughts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
                messages.append(Message(role: .work, work: TurnWork(kind: .thought, id: first.id, words: TurnWork.thoughtWords(thoughts), text: text)))
                thoughts = []
            }
            for item in turn {
                if TurnWork.isThought(item) { thoughts.append(item); continue }
                fold()
                switch item.kind {
                case "asked":
                    guard !item.text.isEmpty else { continue }
                    if item.id == asked?.id, let report {
                        // A subagent's report is its card, never your words.
                        messages.append(Message(role: .work, work: TurnWork(kind: .report, id: item.id, text: report.body,
                                                                             title: report.name, detail: report.gist)))
                        continue
                    }
                    // A repeated question waiting for the Mac is another turn,
                    // even if an earlier turn used exactly the same words.
                    let i = unmatched.firstIndex { send in
                        send.state == .taken && (send.text == item.text || String(send.text.prefix(8000)) == item.text)
                            && (item.began == nil || (item.began ?? 0) >= send.at - 1)
                    }
                    let send = i.map { unmatched.remove(at: $0) }
                    // A row of Now handed over on the Mac: its card over "Do It".
                    let handed = SyncHanded.parse(item.detail).map { Message.Handed(host: $0.host, title: $0.title, detail: $0.detail, from: $0.from) }
                    messages.append(Message(role: .you, text: send?.question ?? item.text, files: files(send), handed: handed))
                case "chose":
                    // What you picked when it asked, as your words under its
                    // question; picked here, it is the send it came from.
                    guard !item.text.isEmpty else { continue }
                    if let i = unmatched.firstIndex(where: { $0.state == .taken && $0.text == item.text }) { unmatched.remove(at: i) }
                    messages.append(Message(role: .you, text: item.text))
                case "message":
                    if TurnWork.said(item), item.name == TurnWork.question {
                        // Its question is its words, never part of its answer.
                        messages.append(Message(role: .answer, text: item.text, by: .claude))
                    } else if TurnWork.said(item) {
                        // An error the agent only repeats is the failure's to say.
                        if last, failed, ChatProblem.repeats(item, failure: head.answer) { continue }
                        answered.append(messages.count)
                        messages.append(Message(role: .answer, text: item.text, by: .claude))
                    } else if !(last && failed && item.name == "error"), let note = TurnWork.note(item, agent: agent) {
                        messages.append(Message(role: .note, text: note))
                    }
                case "card":
                    // What a tool made, a card under the answer, as on the Mac.
                    if let card = ResultCard(json: item.text) { cards.append(card) }
                default: continue
                }
            }
            fold()
            if !cards.isEmpty {
                if let at = answered.last { messages[at].cards = cards }
                else { messages.append(Message(role: .answer, by: .claude, cards: cards)) }
            }
            if last, running {
                live = TurnWork.live(turn)
                continue
            }
            // Once over: Ask Again in the answer's held menu; a turn you
            // stopped says so in a note. Its steps are never shown.
            let steps = TurnWork.steps(turn, ending: ending)
            let words = TurnWork.doneWords(ending, seconds: TurnWork.worked(turn))
            let question = running || report != nil ? nil : asked.map { $0.text }
            let id = turn[0].id
            if ending == "failed" {
                let raw = head.answer.isEmpty ? (turn.last(where: { $0.kind == "message" && $0.name == "error" })?.text ?? "") : head.answer
                let problem = ChatProblem(raw, agent: agent)
                let said = TurnWork(kind: .failure, id: id + ".failure", steps: steps, question: question, title: problem.title, detail: problem.detail)
                failure = said
                messages.append(Message(role: .work, work: said))
            } else if ending != "stopped", let at = answered.last {
                let item = turn.last { TurnWork.said($0) && $0.name != TurnWork.question }
                let text = answered.map { messages[$0].text }.joined(separator: "\n\n")
                messages[at].work = TurnWork(kind: .actions, id: id, words: words, steps: steps, text: text, question: question,
                                             at: (item?.ended ?? item?.began).map(Date.init(timeIntervalSince1970:)))
            } else if ending == "stopped" {
                messages.append(Message(role: .note, text: words))
            }
        }
        if messages.isEmpty, !head.answer.isEmpty, !failed { messages.append(Message(role: .answer, text: head.answer, by: .claude)) }
        // Failed with nothing of its turn kept: still said why.
        if failed, failure == nil {
            let problem = ChatProblem(head.answer, agent: agent)
            let question = messages.last { $0.role == .you }?.text
            messages.append(Message(role: .work, work: TurnWork(kind: .failure, id: head.id + ".failure", question: question,
                                                                 title: problem.title, detail: problem.detail)))
        }
        var waiting = false
        var waitingSend: SyncSend?
        for send in unmatched {
            switch send.state {
            case .waiting:
                messages.append(Message(role: .you, text: send.question ?? send.text, files: files(send)))
                waiting = true
                waitingSend = send
            case .taken:
                // The acknowledgement can arrive before its chat items.
                if head.updated < (send.took ?? send.at) || (head.state == "running") {
                    messages.append(Message(role: .you, text: send.question ?? send.text, files: files(send)))
                    waiting = true
                }
            case .failed, .expired:
                messages.append(Message(role: .you, text: send.question ?? send.text, files: files(send)))
                messages.append(Message(role: .failed, text: sendFailure(send, mac: macs?.name(send.device)) ?? "",
                                        mac: send.state == .expired ? Message.MacWait(send: send.id, expired: true, name: macs?.name(send.device)) : nil))
            case .cancelled:
                // Taken back on this iPhone: gone from the chat.
                continue
            }
        }
        // What it waits for you to pick from: its question stands last, the
        // choices over the field, and no dots, as on the Mac.
        let choices = waiting ? [] : head.asks
        if waiting, let macs, let send = waitingSend {
            // Its Mac by name and why, or the dots while it is up.
            let state = macs.state(send.device)
            if let words = MacWords.waiting(macs.name(send.device) ?? "your Mac", state, sent: Date(timeIntervalSince1970: send.at),
                                            now: now, calendar: calendar) {
                let other = macs.other(send.device, head.cli)
                let wait = Message.MacWait(send: send.id, offerID: other?.id, offerName: other?.name, name: macs.name(send.device))
                if let at = messages.lastIndex(where: { $0.role == .you }) { messages[at].mac = Message.MacWait(send: send.id) }
                messages.append(Message(role: .wait, text: words, by: .claude, mac: wait))
            } else {
                messages.append(Message(role: .typing, by: .claude))
            }
        } else if waiting { messages.append(Message(role: macAsleep ? .wait : .typing, by: .claude)) }
        // Working on it, unless it is waiting on a pick from you: its
        // subagents at work, a card each, over the typing dots.
        // Running, as its Mac last said within six hours: an older Mac's chat
        // left running when Yab quit says so for good, and isn't working.
        else if head.state == "running", now.timeIntervalSince1970 - head.updated < 6 * 3600 {
            if !live.isEmpty { messages.append(Message(role: .work, work: TurnWork(kind: .subagents, id: head.id + ".live", subagents: live))) }
            if choices.isEmpty { messages.append(Message(role: .typing)) }
        }
        let updated = Date(timeIntervalSince1970: head.updated)
        var chat = Chat(id: head.id, title: head.title.isEmpty ? (messages.first?.plain ?? "Chat") : head.title,
                    pinned: head.pinned, unread: head.unread, archived: head.archived,
                    day: day(updated, now: now, calendar: calendar), time: time(updated, now: now, calendar: calendar),
                    by: .claude, macCLI: ChatAgent(rawValue: head.cli)?.rawValue, task: old?.task, taskLike: old?.taskLike ?? false, messages: messages,
                    origin: head.origin, routine: head.routine, project: head.project)
        chat.choices = choices
        return chat
    }

    /// What a send said of its photos and files, for its bubble.
    static func files(_ send: SyncSend?) -> [Message.File] {
        (send?.files ?? []).map { Message.File(name: $0.name, type: $0.type, size: $0.size, digest: $0.digest) }
    }

    static func sendFailure(_ send: SyncSend, mac: String? = nil) -> String? {
        switch send.state {
        case let .failed(reason): return reason.isEmpty ? "Your Mac couldn’t take this question. Send it again." : "Your Mac couldn’t take this question: " + reason
        case .expired: return "This question expired before \(mac ?? "your Mac") received it. Send it again."
        default: return nil
        }
    }

    /// A new question stays recoverable from the journal until its Mac
    /// names a chat. No new local file or second source of sends is needed.
    static func pendingChat(_ send: SyncSend, old: Chat?, macAsleep: Bool, invalidReturn: Bool = false, macs: Macs? = nil,
                            now: Date = Date()) -> Chat? {
        guard let id = send.clientChat, send.state != .cancelled else { return nil }
        let question = send.question ?? send.text
        let message: Message
        var asked: Message.MacWait?
        if invalidReturn { message = Message(role: .failed, text: "Your Mac returned a chat that couldn’t be opened. Send the question again.") }
        else if let error = sendFailure(send, mac: macs?.name(send.device)) {
            message = Message(role: .failed, text: error, mac: send.state == .expired ? Message.MacWait(send: send.id, expired: true, name: macs?.name(send.device)) : nil)
        } else if let macs, send.state == .waiting {
            let state = macs.state(send.device)
            if let words = MacWords.waiting(macs.name(send.device) ?? "your Mac", state, sent: Date(timeIntervalSince1970: send.at), now: now) {
                let other = macs.other(send.device, send.cli)
                message = Message(role: .wait, text: words, by: .claude,
                                  mac: Message.MacWait(send: send.id, offerID: other?.id, offerName: other?.name, name: macs.name(send.device)))
                asked = Message.MacWait(send: send.id)
            } else {
                message = Message(role: .typing, by: .claude)
            }
        }
        else { message = Message(role: macAsleep && send.state == .waiting ? .wait : .typing, by: .claude) }
        let date = Date(timeIntervalSince1970: send.at)
        var chat = old ?? Chat(id: id, title: StandIns.name(for: question, fixturesEnabled: false),
                               day: day(date, now: Date(), calendar: .current), time: time(date, now: Date(), calendar: .current))
        chat.messages.removeAll { $0.role == .typing || $0.role == .wait }
        if !chat.messages.contains(where: { $0.role == .you && $0.text == question }) {
            chat.messages.append(Message(role: .you, text: question, files: files(send)))
        }
        if let at = chat.messages.lastIndex(where: { $0.role == .you && $0.text == question }) { chat.messages[at].mac = asked }
        if chat.messages.last != message { chat.messages.append(message) }
        chat.ephemeral = false
        chat.macCLI = send.cli.flatMap { ChatAgent(rawValue: $0)?.rawValue } ?? chat.macCLI
        // Begun in a project, it is the project's until its Mac's head says.
        chat.project = send.project ?? chat.project
        return chat
    }

    static func day(_ date: Date, now: Date, calendar: Calendar) -> Chat.DateBucket {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        return .earlier
    }

    /// "18:31" today, "Mon" this week, "Aug 14" before.
    static func time(_ date: Date, now: Date, calendar: Calendar) -> String {
        let pattern: String
        if calendar.isDate(date, inSameDayAs: now) { pattern = "HH:mm" }
        else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
                days < 7 { pattern = "EEE" }
        else { pattern = "MMM d" }
        return formatter(pattern, calendar).string(from: date)
    }

    /// One formatter per pattern and calendar: making one is the dearest part
    /// of a chat's row, and an account brings thousands at once.
    private static let formatters = OSAllocatedUnfairLock<[String: DateFormatter]>(initialState: [:])

    private static func formatter(_ pattern: String, _ calendar: Calendar) -> DateFormatter {
        let key = "\(pattern)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        return formatters.withLockUnchecked { all in
            if let made = all[key] { return made }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.calendar = calendar
            format.timeZone = calendar.timeZone
            format.dateFormat = pattern
            all[key] = format
            return format
        }
    }
}
