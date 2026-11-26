import AppKit
import Combine
import SwiftUI
import WebKit

// A button of Yab's in a site's own row, for the one thing it is beside.
//
// A skill says what on its site's pages an action can be about (`item:`
// lines: a Slack message, a Gmail thread) and which of its actions are
// (`action: Reply | @Message | …`). Yab puts a button in the row the site
// keeps for that thing (Slack's hover actions, Gmail's Reply / Forward),
// in the site's own look, and ⌘J over the thing gives the line a chip for
// it rather than the page alone (docs/site-buttons.md).
//
// Saying no is one click wherever the button is: its tooltip says
// right-click, whose menu hides it for that thing, never on the site, or
// everywhere; the View menu and ⌘K have the site's switch; Settings › AI ›
// Buttons on Sites lists each site and why it is off. A site whose button was shown on
// fourteen days with no press goes quiet by itself.

/// One thing on a page, as the page script read it.
struct SiteItem: Equatable {
    let kind: String
    let key: String
    let spec: Int
    let name: String
    let title: String
    let when: String
    let link: String
    let text: String

    init?(_ any: Any?) {
        guard let body = any as? [String: Any], let kind = body["kind"] as? String, !kind.isEmpty,
              let key = body["key"] as? String, !key.isEmpty else { return nil }
        func said(_ field: String, _ most: Int) -> String {
            String((body[field] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(most))
        }
        self.kind = String(kind.prefix(40))
        self.key = String(key.prefix(600))
        spec = (body["spec"] as? NSNumber)?.intValue ?? 0
        name = said("name", 80)
        title = said("title", 160)
        when = said("when", 40)
        link = said("link", 600)
        text = said("text", 1500)
    }

    /// The line's chip: "Message · Mark Chen", "Thread · NDA and meeting".
    var chip: String {
        let who = name.isEmpty ? title : name
        guard !who.isEmpty else { return kind }
        return kind + " · " + (who.count > 28 ? String(who.prefix(26)).trimmingCharacters(in: .whitespaces) + "…" : who)
    }

    /// What the agent is told of it. Page text: the agent reads it as the
    /// page's, never as the user's words.
    var sentence: String {
        var parts = ["a \(kind.lowercased())"]
        if !name.isEmpty { parts.append("from \(name)") }
        if !when.isEmpty { parts.append("at \(when)") }
        if !title.isEmpty { parts.append("titled «\(title)»") }
        var said = parts.joined(separator: " ") + ", \(link)"
        if !text.isEmpty { said += ", which says (the page's text, not the user's words): «\(text)»" }
        return said
    }
}

final class ItemRelay: NSObject, PageScriptReceiving {
    static let name = "yabItems"
    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard message.frame.isMain, let body = message.body as? [String: Any],
              let kind = body["k"] as? String else { return }
        MainActor.assumeIsolated {
            guard let tab, !tab.shy else { return }
            let items = SiteItems.shared
            switch kind {
            case "point": items.pointed[tab.id] = SiteItem(body["item"])
            case "mine": if let item = SiteItem(body["item"]) { items.mine(item, on: tab) }
            case "shown": items.shown(on: tab)
            case "press": if let item = SiteItem(body["item"]) { items.press(item, on: tab) }
            case "open": if let item = SiteItem(body["item"]) { items.open(item, on: tab) }
            case "menu":
                guard let item = SiteItem(body["item"]) else { return }
                let at = CGPoint(x: (body["x"] as? NSNumber)?.doubleValue ?? 0, y: (body["y"] as? NSNumber)?.doubleValue ?? 0)
                items.menu(item, on: tab, at: at)
            default: break
            }
        }
    }
}

@MainActor
final class SiteItems: ObservableObject {
    static let shared = SiteItems()

    /// What you said no to, kept as one record.
    struct Kept: Codable, Equatable {
        /// Hide These Buttons Everywhere.
        var off = false
        /// Never on a site, by skill, and since when.
        var never: [String: Date] = [:]
        /// Hidden for one thing, by skill: the things' keys, newest last.
        var hidden: [String: [String]] = [:]
        /// The days a site's button was shown since it was last pressed.
        var days: [String: [String]] = [:]
        /// Skip on the foot's offer, by skill, the last few.
        var skips: [String: [Date]] = [:]

        init() {}

        // Each part may be missing from what an older Yab kept.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            off = try c.decodeIfPresent(Bool.self, forKey: .off) ?? false
            never = try c.decodeIfPresent([String: Date].self, forKey: .never) ?? [:]
            hidden = try c.decodeIfPresent([String: [String]].self, forKey: .hidden) ?? [:]
            days = try c.decodeIfPresent([String: [String]].self, forKey: .days) ?? [:]
            skips = try c.decodeIfPresent([String: [Date]].self, forKey: .skips) ?? [:]
        }
    }

    /// Skips on the foot's offer within a week before a site stops
    /// getting it; its buttons stay.
    static let skipsToQuiet = 3

    /// Days shown with no press before a site goes quiet by itself.
    static let quietAfter = 14
    static let key = "siteItems"

    @Published private(set) var kept: Kept
    /// The thing the pointer is on, by tab, for ⌘J.
    @Published var pointed: [UUID: SiteItem] = [:]
    /// What the foot's offer on a tab is about (`mine:`).
    private(set) var offered: [UUID: SiteItem] = [:]
    /// Offered once: a key a page said again is not offered again.
    private var told: Set<String> = []
    private let store: UserDefaults

    init(store: UserDefaults = Store.settings) {
        self.store = store
        kept = store.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Kept.self, from: $0) } ?? Kept()
    }

    private func change(_ edit: (inout Kept) -> Void) {
        edit(&kept)
        if let data = try? JSONEncoder().encode(kept) { store.set(data, forKey: Self.key) }
    }

    // MARK: - which sites

    enum State: Equatable { case on, never(Date), quiet, everywhereOff }

    func state(_ skill: String) -> State {
        if kept.off { return .everywhereOff }
        if let since = kept.never[skill] { return .never(since) }
        if (kept.days[skill]?.count ?? 0) >= Self.quietAfter { return .quiet }
        return .on
    }

    /// The skills with buttons, for Settings: each with its name.
    var sites: [(skill: String, name: String)] {
        Skills.all().filter { skill in skill.items.contains { item in skill.actions.contains { $0.pattern == item.tag } } }
            .map { ($0.name, Self.name($0.name)) }
    }

    /// The skill whose buttons a page would have, if any.
    func skill(for url: URL?) -> String? {
        Skills.items(for: url).first?.actions.first?.skill
    }

    /// How a skill is said: "Slack", "GitHub".
    static func name(_ skill: String) -> String {
        let said = ["github": "GitHub", "linkedin": "LinkedIn", "gmail": "Gmail", "x-twitter": "X", "google-calendar": "Google Calendar"]
        return said[skill] ?? skill.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: - the page script

    /// The script a tab going to `host` gets, or nil: none in a private
    /// tab, with agents paused, or where you said no.
    func script(for tab: Tab, host: String?) -> String? {
        guard !tab.shy, !kept.off, Store.settings.bool(forKey: "bench"), Agents.ready, let host,
              let url = URL(string: "https://" + host + "/"), Skills.mayHave(url) else { return nil }
        let agent = Agents.preferredName
        let ask = Keymap.shared.text(.agentAsk)
        var specs: [[String: Any]] = []
        var skills: Set<String> = []
        for (item, actions) in Skills.items(for: url) {
            guard let skill = actions.first?.skill, state(skill) == .on else { continue }
            skills.insert(skill)
            let first = actions[0].title
            specs.append([
                "kind": item.kind, "container": item.container, "anchor": item.anchor, "place": item.place,
                "min": item.min, "text": item.text, "style": item.style, "like": item.like, "name": item.name, "link": item.link,
                "when": item.when, "body": item.body, "title": item.title, "mine": item.mine,
                "gate": item.gate, "icon": item.icon, "stroke": item.stroke, "hover": item.hover,
                "label": Self.words(item.button), "full": Self.label(item.button, agent: agent),
                "tip": "\(first) with \(agent)\n\(ask) for more · Right-click to hide",
            ])
        }
        guard !specs.isEmpty else { return nil }
        let hidden = skills.sorted().flatMap { kept.hidden[$0] ?? [] }
        return Self.template.replacingOccurrences(of: "__YAB_SPECS__", with: Self.json(specs))
            .replacingOccurrences(of: "__YAB_HIDDEN__", with: Self.json(hidden))
    }

    /// Read once: every navigation asks for the script.
    private static let template = PageScript.load("site-items")

    /// The button's words: the verb alone, "Do It", "Ask about this". Who
    /// does it is the face's to show, and the tooltip's to say.
    nonisolated static func words(_ button: String) -> String {
        button.replacingOccurrences(of: " {agent}", with: "").replacingOccurrences(of: "{agent}", with: "")
    }

    /// Its name, for the tooltip and VoiceOver: "Do It with Claude"; a verb
    /// that names the agent itself keeps its own words: "Ask {agent} about
    /// this" is "Ask Claude about this".
    nonisolated static func label(_ button: String, agent: String) -> String {
        button.contains("{agent}") ? button.replacingOccurrences(of: "{agent}", with: agent) : "\(button) with \(agent)"
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "[]" }
        // In a script, not in a string: these two end a line in JavaScript.
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // MARK: - what the page said

    /// The button was in front of you today.
    func shown(on tab: Tab) {
        if let skill = skill(for: tab.address) { seen(skill) }
    }

    /// Fourteen days of it, never pressed: quiet from the next page on.
    func seen(_ skill: String, on date: Date = Date()) {
        let day = Self.day(date)
        guard kept.days[skill]?.contains(day) != true else { return }
        change { $0.days[skill, default: []].append(day) }
    }

    /// Pressed: the count of days starts over.
    func pressed(_ skill: String) {
        guard kept.days[skill] != nil else { return }
        change { $0.days[skill] = nil }
    }

    static func day(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - addressed to you

    /// A thing addressed to you came on the page (`mine:`): the foot offers
    /// its first action, with Skip and Never on the site beside it. Once a
    /// thing, never over another offer, and not where Skip was said three
    /// times this week.
    func mine(_ item: SiteItem, on tab: Tab) {
        guard let action = actions(for: item, on: tab).first, state(action.skill) == .on, !footQuiet(action.skill),
              !told.contains(item.key), Hints.shared.offered[tab.id] == nil, let here = tab.address?.absoluteString else { return }
        told.insert(item.key)
        offered[tab.id] = item
        Hints.shared.extra[tab.id] = action
        Hints.shared.offered[tab.id] = here
    }

    /// The thing an offer's action is about, when it is one of these.
    func item(offeredOn tab: Tab, for action: Skills.Action) -> SiteItem? {
        action.pattern.hasPrefix("@") ? offered[tab.id] : nil
    }

    /// Skip on the foot's offer: counted, and the corner asks whether to
    /// stop suggesting on the site, the way back if Skip meant more.
    func skip(_ skill: String, from browser: Browser?) {
        skipped(skill)
        browser?.toaster.pop("Skipped", mark: "agent.face", undo: { [weak self, weak browser] in self?.never(skill, from: browser) },
                             act: "Don’t Suggest on \(Self.name(skill))")
    }

    func skipped(_ skill: String, on date: Date = Date()) {
        change { kept in
            let week = date.addingTimeInterval(-7 * 86_400)
            kept.skips[skill] = (kept.skips[skill, default: []] + [date]).filter { $0 > week }.suffix(10)
        }
    }

    /// Skipped three times this week: no more offers at its foot.
    func footQuiet(_ skill: String, now: Date = Date()) -> Bool {
        let week = now.addingTimeInterval(-7 * 86_400)
        return (kept.skips[skill] ?? []).filter { $0 > week }.count >= Self.skipsToQuiet
    }

    /// The actions about a thing on this tab's page, its button's first.
    func actions(for item: SiteItem, on tab: Tab) -> [Skills.Action] {
        let found = Skills.items(for: tab.address).filter { $0.item.kind == item.kind }
        return found.first?.actions ?? []
    }

    func press(_ item: SiteItem, on tab: Tab) {
        guard let action = actions(for: item, on: tab).first else { return }
        pressed(action.skill)
        // One task a thing: a press while its last is under way goes to it.
        if let id = begun[Self.place(tab, item.key)], Agents.shared.session(id)?.state.live == true { open(item, on: tab); return }
        guard Agents.ready else { tell(tab, item.key, ""); TaskLine.connect(); return }
        let session = Agents.shared.act(action, on: tab, item: item)
        begun[Self.place(tab, item.key)] = session.id
        follow(session.id, tab: tab, key: item.key)
    }

    /// The face pressed while its task works, asks or is done: its chat in
    /// the column, the tab it works in in front.
    func open(_ item: SiteItem, on tab: Tab) {
        guard let id = begun[Self.place(tab, item.key)], let browser = BrowserWindows.shared.owner(of: tab.id)?.browser else { return }
        browser.select(tab)
        browser.showChat(id)
        if Agents.shared.session(id)?.state.live != true { tell(tab, item.key, "") }
    }

    /// The task a button began, by tab and thing.
    private var begun: [String: String] = [:]
    private static func place(_ tab: Tab, _ key: String) -> String { tab.id.uuidString + "|" + key }

    // MARK: - the task on the button's face

    /// Tasks begun from a button, followed until they end: the button's
    /// face works while it does, raises its hand when it needs you, and
    /// ticks when it is done, as the task's own face does in its folder.
    private struct Followed { let tab: UUID; let key: String; var said: String? }
    private var followed: [String: Followed] = [:]
    private var watching: AnyCancellable?

    private func follow(_ id: String, tab: Tab, key: String) {
        followed[id] = Followed(tab: tab.id, key: key, said: nil)
        if watching == nil {
            watching = Agents.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() }
        }
        update()
    }

    /// What the face says of a task: "work", "hand", "done", or "" when it stopped.
    nonisolated static func face(_ state: Agents.State, asking: Bool) -> String {
        guard state.live else { return state == .done ? "done" : "" }
        return asking ? "hand" : "work"
    }

    private func update() {
        let agents = Agents.shared
        for (id, followed) in followed {
            guard let tab = tabs().first(where: { $0.id == followed.tab }) else { self.followed[id] = nil; continue }
            let session = agents.session(id)
            let asking = session.map { $0.permission != nil || $0.asking != nil } == true || tab.handoff != nil
            let face = session.map { Self.face($0.state, asking: asking) } ?? ""
            if face != followed.said {
                self.followed[id]?.said = face
                let name = session?.name ?? Agents.preferredName
                let tip = ["work": "\(name) is on it", "hand": "\(name) needs you", "done": "Done"][face]
                tell(tab, followed.key, face, tip: tip)
            }
            if face != "work", face != "hand" { self.followed[id] = nil }
        }
        if followed.isEmpty { watching = nil }
    }

    private func tell(_ tab: Tab, _ key: String, _ face: String, tip: String? = nil) {
        let args = Self.json([key, face, tip ?? ""])
        tab.builtPage?.runInYab("window.__yabItems && window.__yabItems.state.apply(null, \(args))")
    }

    // MARK: - saying no

    func menu(_ item: SiteItem, on tab: Tab, at point: CGPoint) {
        guard let skill = skill(for: tab.address) else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hand = MenuHand.shared
        hand.tab = tab
        hand.item = item
        hand.skill = skill
        for (title, tag) in [("Hide for This \(item.kind)", 1), ("Never on \(Self.name(skill))", 2), ("Hide These Buttons Everywhere", 3)] {
            let row = NSMenuItem(title: title, action: #selector(MenuHand.pick(_:)), keyEquivalent: "")
            row.target = hand
            row.tag = tag
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(MenuHand.pick(_:)), keyEquivalent: "")
        settings.target = hand
        settings.tag = 4
        menu.addItem(settings)
        let page = tab.page
        let web = page
        let zoom = page.pageZoom
        let y = point.y * zoom
        menu.popUp(positioning: nil, at: NSPoint(x: point.x * zoom, y: web.isFlipped ? y : web.bounds.height - y), in: web)
    }

    @MainActor private final class MenuHand: NSObject {
        static let shared = MenuHand()
        weak var tab: Tab?
        var item: SiteItem?
        var skill = ""

        @objc func pick(_ row: NSMenuItem) {
            guard let tab, let item else { return }
            let items = SiteItems.shared
            let browser = BrowserWindows.shared.owner(of: tab.id)?.browser
            switch row.tag {
            case 1: items.hide(item, skill: skill)
            case 2: items.never(skill, from: browser)
            case 3: items.everywhere(false, from: browser)
            case 4: if let browser { SettingsWindow.shared.show(.siteButtons, for: browser) }
            default: break
            }
        }
    }

    /// Gone from this one thing, here and after a reload.
    func hide(_ item: SiteItem, skill: String) {
        change { kept in
            var keys = kept.hidden[skill, default: []].filter { $0 != item.key }
            keys.append(item.key)
            kept.hidden[skill] = Array(keys.suffix(300))
        }
        let key = Self.json([item.key])
        every(skill) { $0.builtPage?.runInYab("window.__yabItems && window.__yabItems.hide(\(key)[0])") }
    }

    /// Never on a site, with the way back in the corner while it is up.
    func never(_ skill: String, from browser: Browser?) {
        set(skill, on: false)
        browser?.toaster.pop("Won’t suggest on \(Self.name(skill))", undo: { [weak self] in self?.set(skill, on: true) })
    }

    /// Hide These Buttons Everywhere, or back.
    func everywhere(_ on: Bool, from browser: Browser?) {
        change { $0.off = !on }
        for tab in tabs() { on ? arm(tab) : off(tab) }
        if !on {
            browser?.toaster.pop("Buttons on sites are off", undo: { [weak self] in self?.everywhere(true, from: nil) })
        }
    }

    /// A site's switch: Settings, the View menu, ⌘K. On again starts the
    /// count of days over and puts the buttons back without a reload.
    func set(_ skill: String, on: Bool) {
        change { kept in
            if on {
                kept.never[skill] = nil
                kept.days[skill] = nil
                kept.skips[skill] = nil
            } else {
                kept.never[skill] = Date()
            }
        }
        every(skill) { tab in on ? self.arm(tab) : self.off(tab) }
    }

    /// Whether this tab's site has buttons that are showing.
    func showing(on tab: Tab?) -> Bool? {
        guard let tab, !tab.shy, let skill = skill(for: tab.address) else { return nil }
        return state(skill) == .on
    }

    /// The View menu and ⌘K: this tab's site, off or on.
    func toggle(on tab: Tab?, from browser: Browser?) {
        guard let tab, let skill = skill(for: tab.address) else { return }
        if kept.off { everywhere(true, from: nil); if state(skill) == .on { return } }
        if state(skill) == .on { never(skill, from: browser) } else { set(skill, on: true) }
    }

    private func off(_ tab: Tab) {
        tab.builtPage?.runInYab("window.__yabItems && window.__yabItems.off()")
    }

    /// The script into a page that is already open, as its next one would get.
    private func arm(_ tab: Tab) {
        guard let source = script(for: tab, host: PageScripts.host(of: tab.address)) else { return }
        tab.builtPage?.runInYab("if (window.__yabItems) { window.__yabItems.resume(); } else { \(source) }")
    }

    private func tabs() -> [Tab] {
        BrowserWindows.shared.browsers.flatMap(\.everyTab).filter { !$0.shy }
    }

    private func every(_ skill: String, _ act: (Tab) -> Void) {
        for tab in tabs() where self.skill(for: tab.address) == skill { act(tab) }
    }

    /// What Settings says under a site.
    func detail(_ skill: String) -> String {
        switch state(skill) {
        case .on where footQuiet(skill): return "Buttons only: you skipped its suggestions 3 times this week"
        case .on: return "Buttons in its own rows, and ⌘J over what you point at"
        case .never(let since): return "Off since \(since.formatted(AppDates.dateTime.month(.abbreviated).day())), you chose Never"
        case .quiet: return "Hidden, unused for 2 weeks"
        case .everywhereOff: return "Off with every site"
        }
    }
}

/// View › Hide Claude Buttons on Slack, on a site that has them: the
/// site's name in it, so Help's search finds it by "button" or "Slack".
struct SiteButtonsCommand: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var items = SiteItems.shared

    var body: some View {
        // The site's skill as the menu bar last read it (MenuFront), not
        // the tab's address, which would run the menu bar again at every
        // link's start.
        if let tab = browser.active, let skill = browser.menuSiteSkill {
            let showing = items.state(skill) == .on
            let site = SiteItems.name(skill)
            Button("\(showing ? "Hide" : "Show") \(Agents.preferredName) Buttons on \(site)") {
                items.toggle(on: tab, from: browser)
            }
        }
    }
}

/// Settings › AI › Buttons on Sites: Yab's buttons in sites' own rows, all
/// of them, and a row for each site, its mark, what its button offers
/// while on or why it is off, opening its own page (SiteButtonsSitePage).
struct SiteButtonsSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var items = SiteItems.shared

    var body: some View {
        if let opened = model.opened, let skill = Skills.named(opened) {
            SiteButtonsSitePage(skill: skill)
                .id(opened)
        } else {
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        PageHero(page: .siteButtons)
        Section {
            SettingsRow("Buttons on sites", detail: "When off, page actions remain available with ⌘J.") {
                Toggle("Buttons on sites", isOn: Binding(get: { !items.kept.off }, set: { items.everywhere($0, from: nil) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("site-buttons-all")
        }
        Section {
            ForEach(items.sites, id: \.skill) { site in
                if let skill = Skills.named(site.skill) {
                    row(site.name, skill)
                }
            }
        } header: {
            Text("Sites").foregroundStyle(.secondary)
        }
    }

    private func row(_ name: String, _ skill: Skills.Skill) -> some View {
        HStack(spacing: 12) {
            SkillMark(skill: skill, size: 20)
            SettingsRow(name, detail: items.state(skill.name) == .on ? SiteButtonsSitePage.offers(skill) : items.detail(skill.name)) {
                SettingsChevron()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.open(.siteButtons, item: skill.name) }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(name)")
        .accessibilityAddTraits(.isButton)
        .settingsAnchor("site-buttons-" + skill.name)
    }
}

/// One site's buttons: its switch, and what each of its button's actions
/// asks the agent, in words to change in place.
private struct SiteButtonsSitePage: View {
    let skill: Skills.Skill
    @ObservedObject private var items = SiteItems.shared
    /// Bumped by a prompt kept, so the fields read the skill again.
    @State private var edits = 0

    private var name: String { SiteItems.name(skill.name) }

    var body: some View {
        let skill = edits >= 0 ? (Skills.named(self.skill.name) ?? self.skill) : self.skill
        Section {} header: {
            VStack(spacing: 0) {
                SkillMark(skill: skill, size: 56)
                    .padding(.bottom, 12)
                Text(name)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                Text(Self.offers(skill))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 5) // design: PageHero's gap under the name
            }
            .foregroundStyle(.primary)
            .textCase(nil)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 18) // design: PageHero's air above the first group
            .accessibilityElement(children: .combine)
        }
        Section {
            SettingsRow("Buttons on \(name)", detail: items.detail(skill.name)) {
                Toggle(name, isOn: Binding(get: { items.state(skill.name) == .on },
                                           set: { items.set(skill.name, on: $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .disabled(items.kept.off)
        }
        Section {
            ForEach(skill.actions.filter { $0.pattern.hasPrefix("@") }, id: \.title) { action in
                SitePromptField(action: action) { edits += 1 }
            }
        } header: {
            Text("Prompts").foregroundStyle(.secondary)
        }
    }

    /// "Handle It: Do What It Asks, Draft a reply", the button and its menu.
    static func offers(_ skill: Skills.Skill) -> String {
        var said: [String] = []
        for item in skill.items {
            let actions = skill.actions.filter { $0.pattern == item.tag }.map(\.title)
            let line = "\(item.button.isEmpty ? item.kind : item.button): " + actions.joined(separator: ", ")
            if !actions.isEmpty, !said.contains(line) { said.append(line) }
        }
        return said.joined(separator: " · ")
    }
}

/// One action of a site's button, what it asks the agent in words you can
/// change: kept a moment after the last key, Reset once they are yours.
private struct SitePromptField: View {
    let action: Skills.Action
    let kept: () -> Void
    @State private var text: String

    init(action: Skills.Action, kept: @escaping () -> Void) {
        self.action = action
        self.kept = kept
        _text = State(initialValue: action.prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(action.title)
                Spacer()
                if action.written != nil {
                    Button("Reset") {
                        text = action.written ?? text
                        SkillPrompts.set("", for: action)
                        kept()
                    }
                    .settingsButton()
                }
            }
            // Grows with the words, as tall as the whole prompt.
            TextField(action.title, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .labelsHidden()
                .lineLimit(2...14)
                .font(.system(size: 13))
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                .accessibilityLabel(action.title + " prompt")
        }
        .task(id: text) {
            guard text != action.prompt else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            SkillPrompts.set(text, for: action)
            kept()
        }
    }
}
