import AppKit
import Combine
import SwiftUI

// Settings › Agents: Claude Code and Codex, connected to yab, and what they
// may do once they are.
//
// Until one is connected the page is a way in, in the middle of the pane
// (AgentsIntro): the agents on this Mac first,
// one button. Connect signs the CLI in to your plan in a tab of yours and
// puts yab where it looks (AgentSetup: the skill, the tools, the command and
// its PATH line), and then shows how to ask for it once (AgentsTry). After
// that it is the page: the agents, what they may do, where it all went.
//
// A page further in, with a head of its own, is kept for what is a thing in
// its own right, as History is under Privacy: here the routines, memory
// (MemorySettings) and skills (SkillSettings). A list that
// belongs to a setting stays on the page as a group under a plain heading,
// the way Search lists its sites: the sites agents act on without asking or
// never, shown only once there is one. Status is read from the files
// (AgentSetup.status), so what the page says is what is on disk.

/// Settings › AI: the hub, Raycast's AI page. The models and the plans
/// they come from, the two ways yab uses them (Commands on selected text,
/// Agents on tasks), and what agents keep. Until a plan is connected the
/// page is the way in instead (AgentsIntro), unless the welcome did it.
struct AIPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel
    @ObservedObject private var routines = Routines.shared
    @ObservedObject private var setup = AgentSetupModel.shared
    @ObservedObject private var agents = Agents.shared
    @ObservedObject private var memory = MemoryShelf.shared
    @ObservedObject private var skills = SkillShelf.shared
    @ObservedObject private var defaults = ModelDefaults.shared
    @ObservedObject private var siteItems = SiteItems.shared

    var body: some View {
        PageHero(page: .ai)
        AISwitchSettings(prefs: prefs)
        // Off: everything under the switch stays, paler, and still opens.
        Group {
            rows
        }
        .opacity(prefs.aiUse == .off ? 0.5 : 1) // design: Off's rows, dimmed as the mockup draws them
    }

    @ViewBuilder private var rows: some View {
        Section {
            FeatureRow(.models, detail: modelsDetail, model: model)
                .settingsAnchor("ai-models")
            FeatureRow(.commands, detail: commandsDetail, model: model)
                .settingsAnchor("ai-commands")
            FeatureRow(.whileYouBrowse, detail: WhileYouBrowsePage.summary(prefs), model: model)
                .settingsAnchor("ai-while-you-browse")
        }
        Section {
            FeatureRow(.agents, detail: agentsDetail, model: model)
                .settingsAnchor("ai-agents")
            FeatureRow(.agentRoutines, detail: routinesDetail, model: model)
                .settingsAnchor("agents-routines")
            FeatureRow(.agentMemory, detail: memoryDetail, model: model)
                .settingsAnchor("agents-memory")
            FeatureRow(.agentSkills, detail: skillsDetail, model: model)
                .settingsAnchor("agents-skills")
            FeatureRow(.siteButtons, detail: siteButtonsDetail, model: model)
                .settingsAnchor("ai-site-buttons")
            FeatureRow(.assistants, detail: "Connect dots, Muse or Grok Bot to Yab.", model: model)
                .settingsAnchor("ai-assistants")
        }
        BoostAISettings()
        .task {
            memory.reload()
            skills.reload()
            await setup.look()
        }
        .onAppear { setup.showing("settings.ai", true) }
        .onDisappear { setup.showing("settings.ai", false) }
    }

    /// "Claude and ChatGPT plans, and this Mac", as connected.
    private var modelsDetail: String {
        let plans = AgentSetupModel.clis.filter { setup.connected($0) }.map { AgentSetupModel.plan($0) }
        let said = plans.isEmpty ? "No plan connected" : AgentSetupModel.list(plans) + (plans.count == 1 ? " plan" : " plans")
        return FormModel.ready ? said + ", and this Mac" : said
    }

    private var commandsDetail: String {
        let on = browser.selectionCommands.commands.filter(\.enabled).count
        return "\(on) on selected text, " + (defaults[.commands].cli == nil ? "on this Mac or your agent" : "longer ones on \(defaults.name(.commands))")
    }

    /// "On in 7 sites", or Off.
    private var siteButtonsDetail: String {
        let on = siteItems.sites.filter { siteItems.state($0.skill) == .on }.count
        if siteItems.kept.off || on == 0 { return "Off. Page actions remain available with ⌘J." }
        return "On in \(on) \(on == 1 ? "site" : "sites")"
    }

    private var agentsDetail: String {
        prefs.bench ? "Manage task permissions in your tabs."
            : "Paused. Agents can't use Yab."
    }

    /// How far Get to Know Me has got while it runs, else what is kept.
    private var memoryDetail: String {
        if let session = setup.knowingNow { return MemoryKnowing.line(session) }
        if !prefs.agentsRemember { return "Off. Agent memory is disabled." }
        let notes = memory.notes.count
        return notes == 0 ? "Agent memory stored on this Mac." : "\(notes) \(notes == 1 ? "note" : "notes") about you, kept on this Mac."
    }

    /// "26 built in, 1 yours".
    private var skillsDetail: String {
        let built = skills.builtIn.count
        let yours = skills.yours.count
        if built + yours == 0 { return "Site instructions for agents." }
        return yours == 0 ? "\(built) built in" : "\(built) built in, \(yours) yours"
    }

    private var routinesDetail: String {
        switch routines.all.count {
        case 0: return "Scheduled tasks. Requires Yab to be open."
        case 1: return routines.all[0].name
        default: return "\(routines.all.count) routines"
        }
    }
}

/// Settings › AI's first card: AI in Yab, On, When Asked or Off (AIUse),
/// and what ⌘J opens on a page, a field or a chat beside it. Let agents use
/// Yab is a switch of its own: at the top of Settings › AI › Agents and on
/// Settings › Developers, one setting (`bench`) in both places.
struct AISwitchSettings: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var askKey = Keymap.shared.slot(.agentAsk)

    var body: some View {
        Section {
            SettingsRow("AI in Yab", detail: AIUse.detail(prefs.aiUse)) {
                GlassTrack(title: "AI in Yab", options: AIUse.Level.allCases.map { ($0.title, $0) }, selection: $prefs.aiUse)
                    .frame(width: 270)
            }
            .settingsAnchor("ai-use")
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own gap
                    Text(SettingsWords.text("Default view"))
                    SettingsText((askKey.keys.map { $0.settingsHint + " " } ?? "The assigned shortcut ") + (prefs.askOpens == .line
                                 ? "opens a field on the page; twice, a chat."
                                 : "opens a chat beside the page."))
                        .fixedSize(horizontal: false, vertical: true)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GlassTrack(title: "Default view", options: AskOpens.allCases.map { ($0.title, $0) }, selection: $prefs.askOpens)
                    .frame(width: 160)
            }
            // Off: as the rows below it, paler and still there.
            .opacity(prefs.aiUse == .off ? 0.5 : 1) // design: Off's rows, dimmed as the mockup draws them
            .settingsAnchor("agents-ask-opens")
        }
    }
}

/// Settings › AI › Agents: what agents may do on their own, the sites
/// they act on without asking, and where Connect put things. The agents
/// themselves, and their plans, are in Models.
struct AgentsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel
    @ObservedObject private var rules = AgentRules.shared
    @ObservedObject private var setup = AgentSetupModel.shared
    /// What macOS lets Yab say, read and never asked for (MailNotify).
    @ObservedObject private var notify = MailNotify.shared
    @ObservedObject private var sync = SyncCenter.shared
    /// How long an untouched chat stays out of Archived Chats (Chat.archiveAfter).
    @AppStorage(Chat.archiveKey, store: Store.settings) private var archiveChats = Tidy.month

    var body: some View {
        PageHero(page: .agents)
        Section("Permissions") {
            SettingsRow("Agents ask first", detail: prefs.agentsAsking.detail) {
                GlassTrack(title: "Agents ask first", options: AgentAsking.allCases.map { ($0.title, $0) }, selection: $prefs.agentsAsking)
                    .frame(width: 220)
            }
            .settingsAnchor("agents-asking")
            SettingsRow("Pay without asking up to", detail: payDetail) {
                GlassTrack(title: "Pay without asking up to", options: AgentRules.limits.map { ($0 == 0 ? "Off" : "$\($0)", $0) }, selection: $rules.payLimit)
                    .frame(width: 220)
            }
            .settingsAnchor("agents-pay")
            SettingsRow("Messages", detail: "Allow local tasks to read Messages and verification codes. Sending always requires approval.") {
                Toggle(SettingsWords.text("Messages"), isOn: $prefs.agentsMessages)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("agents-messages")
            SettingsRow("Ask on my other devices", detail: elsewhereDetail) {
                Toggle(SettingsWords.text("Ask on my other devices"), isOn: $prefs.agentsAskElsewhere)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!sync.on)
            }
            .settingsAnchor("agents-elsewhere")
            SettingsRow("Sound for questions", detail: "Play a sound when an agent needs your response.") {
                Toggle(SettingsWords.text("Sound for questions"), isOn: $prefs.agentsAskSound)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("agents-ask-sound")
            // An agent that needs you, or is done, says so behind other apps
            // only where macOS lets Yab already: asked only from here.
            if notify.permission != .allowed {
                SettingsRow("Notifications are off for Yab", detail: notify.permission == .denied
                            ? "Allow notifications in System Settings for task completion and approval requests."
                            : "Allow notifications for task completion and approval requests.") {
                    Button("Allow…") { Task { await notify.allow() } }
                        .settingsButton()
                }
                .settingsAnchor("agents-notify-allow")
            }
            SettingsNote("Agent tabs stay in the background. Clicking your tab takes control from the agent.")
        }
        if !rules.rules.isEmpty {
            AgentSites()
        }
        Section("Chats") {
            SettingsRow("Archive chats you haven't opened in", detail: "Pinned chats stay.") {
                DropMenu("Archive chats you haven't opened in", options: Tidy.allCases.map { (title: $0.title, value: $0) },
                         selection: $archiveChats)
                    .fixedSize()
                    .onChange(of: archiveChats) { Chats.shared.archiveOld() }
            }
            .settingsAnchor("agents-chats-archive")
        }
        Section {
            SettingsRow("Agents in One Row", detail: "Group routine and terminal-agent tabs in one sidebar row. Expand when attention is needed.") {
                Toggle("Agents in One Row", isOn: $prefs.agentRow)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("agents-row")
        }
        Section {
            // Where each piece Connect put in is, one at a time: Developers.
            FeatureRow(.developers, detail: "Command-line and browser tools for Claude Code and Codex.", model: model)
            HStack(spacing: 8) {
                Button("Show How to Ask") { setup.showHowToAsk() }
                    .settingsButton()
                Spacer()
                Button(SettingsWords.text("Disconnect")) { setup.disconnect(AgentSetupModel.clis.filter { setup.connected($0) }, browser) }
                    .buttonStyle(.yab(.secondary, .regular, tint: .red))
                    .disabled(setup.busy)
            }
            .settingsAnchor("agents-details")
        }
        .task {
            await setup.look()
            await notify.refresh()
        }
        .onAppear { setup.showing("settings.agents", true) }
        .onDisappear { setup.showing("settings.agents", false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await setup.look()
                await notify.refresh()
            }
        }
        // `yab setup` or `yab remove` in a terminal, while this is open.
        .onReceive(DistributedNotificationCenter.default().publisher(for: Cli.setUp, object: Bundle.main.bundleIdentifier as NSString?)) { _ in
            setup.reread()
        }
    }

    /// Where a yes can come from besides this Mac, as Sync has it now.
    private var elsewhereDetail: String {
        guard sync.on else { return "Needs Sync." }
        let names = sync.assistantAnswerers.map(\.name)
        guard !names.isEmpty else { return "Questions to pay, send or upload also go to your iPhone or another Mac in Sync." }
        return "Questions to pay, send or upload also go to \(ListFormatter.englishString(byJoining: names))."
    }

    /// This month's spending once there is some, else what the threshold means.
    private var payDetail: String {
        if rules.paidThisMonth > 0 { return String(format: "Agents paid $%.2f this month.", rules.paidThisMonth) }
        return rules.payLimit == 0
            ? "Every payment asks first."
            : "Less than this goes through; after $\(rules.payLimit * 10) in a month, every payment asks."
    }
}

// MARK: - sites

/// The sites agents act on without asking, or never, as Search lists its
/// sites: a group on the Agents page under a plain heading, there once a
/// card has made one. Only taken back or turned round here, never made.
private struct AgentSites: View {
    @ObservedObject private var rules = AgentRules.shared
    @State private var filter = ""

    var body: some View {
        Section {
            ForEach(shown) { rule in
                AgentSiteRow(rule: rule, icon: Favicons.shared.cached(rule.site) ?? Favicons.shared.cached("www." + rule.site))
                    .settingsAnchor(rule.id == shown.first?.id ? "agents-sites" : "agents-site-" + rule.id)
            }
            if shown.isEmpty {
                Text("No site called “\(filter)”")
                    .foregroundStyle(.secondary)
            }
        } header: {
            // A heading like the page's others; the filter only once there
            // are enough sites to look for one.
            if rules.rules.count > 6 {
                HStack(spacing: 8) {
                    Text(SettingsWords.text("Sites"))
                    Spacer()
                    TextField("Filter", text: $filter, prompt: Text("Filter"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .labelsHidden()
                }
                .textCase(nil)
            } else {
                // In the gray a titled group's heading is set in.
                Text(SettingsWords.text("Sites")).foregroundStyle(.secondary)
            }
        } footer: {
            SettingsNote("Choose Always here on an approval card, or hold ⌥ for Never here. Payments and Messages always require approval.")
        }
    }

    private var shown: [AgentRules.Rule] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return rules.rules
            .filter { needle.isEmpty || $0.site.contains(needle) || $0.verb.lowercased().contains(needle) }
            .sorted { ($0.site, $0.verb) < ($1.site, $1.verb) }
    }
}

/// One rule: the site's mark and name, the press, and always or never,
/// turned round in place; Remove on a right click, as in Search.
private struct AgentSiteRow: View {
    let rule: AgentRules.Rule
    let icon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) { // design: the same gap as Search's site rows, which this table matches
                Mark(icon: icon, letter: rule.site.first.map { String($0).uppercased() } ?? "", size: 16)
                Text(rule.site).lineLimit(1)
                Text(rule.verb)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The tables' cell, as Shortcuts keeps its keys: the choice
            // bare, the menu on a click.
            MenuCell(title: rule.site, options: [("Without asking", .always), ("Never", .never)], selection: Binding(
                get: { rule.verdict },
                set: { AgentRules.shared.set(site: rule.site, label: rule.verb, $0) }
            ))
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(SettingsWords.text("Remove")) { AgentRules.shared.remove(rule) }
        }
        .onAppear { Favicons.shared.fetch(host: rule.site) }
    }
}

// MARK: - what is set up

/// What Connect put in place, read from the files, and the work of putting
/// it there: shared by the Agents page, its way in, Models, the welcome and
/// the new tab's hint. A press changes something on screen at once: the
/// state is set before anything runs, and every running state has a word
/// and the ring (docs/agents.md, "Connect, state by state").
@MainActor
final class AgentSetupModel: ObservableObject {
    static let shared = AgentSetupModel()

    static let clis = AgentPlan.connectable.map(\.cli)

    let consent: ProviderConsent
    @Published private(set) var status: AgentSetup.Status
    @Published private(set) var found: Shell.Found?
    /// Whether each CLI is signed in to its plan, once asked.
    @Published private(set) var signedIn: [String: Bool] = [:]
    /// The row being worked on.
    @Published private(set) var working: String?
    private var disconnectWork: UUID?
    func beginDisconnectWork(_ name: String) -> UUID {
        let id = UUID(); disconnectWork = id; working = name; return id
    }
    func endDisconnectWork(_ id: UUID) {
        if disconnectWork == id { disconnectWork = nil; working = nil }
    }
    /// Where Connect is, while it is under way or has just finished; nil
    /// on the page itself.
    @Published var flow: Flow?
    /// The agents ticked on the way in.
    @Published var picks: Set<String> = []
    /// When each agent last opened a tab of its own in yab.
    @Published private(set) var lastUse: [String: Date] = [:]
    /// The agent that opened its first tab while How to Ask was showing.
    @Published private(set) var tried: String?
    /// Get to Know Me's task, while it runs.
    @Published private(set) var knowing: String?
    /// The install couldn't be done from here: the command is to paste.
    @Published private(set) var installByHand = false
    /// Where the sign-in page is, while `.signingIn`: opening, in a Yab
    /// tab, or in another browser (Codex opens its own).
    @Published private(set) var page: Agents.SignInPage?
    /// The last try's failure, in words, beside what was pressed until the
    /// next press.
    @Published private(set) var trouble: Trouble?
    /// The account id signing in again, from Models: its row shows the
    /// steps, and it ends quietly, with no tick, How to Ask or offer.
    @Published private(set) var renewing: String?
    /// Installing for over two minutes.
    @Published private(set) var slow = false
    /// The agent Connect is connecting with an API key of yours rather
    /// than a plan's sign-in, while it runs (AgentKey).
    @Published private(set) var keying: String?
    /// Use an API Key's field is open on the way in, for this agent.
    @Published var keyFor: String?
    /// A key waiting for its agent's install to finish.
    private var pendingKey: (cli: String, key: String)?

    /// Bumped by every press and by Cancel: a run that finds it has moved
    /// on stops where it is, so a late answer never undoes a Cancel.
    private var attempt = 0
    /// The installer while it runs: Cancel stops it and what it started.
    private var installer: InstallRun?

    enum Flow: Equatable {
        /// Pressed: a login shell asked where it is, and the CLI whether
        /// it is signed in.
        case preparing([String])
        /// Waiting for an install, here or in Terminal, to finish.
        case installing(String)
        /// Its sign-in page open, where `page` says.
        case signingIn(String)
        /// Signed in: the skill, the tools, the command and its PATH line
        /// put in place.
        case finishing([String])
        /// Done, the tick on its mark for a moment.
        case landed([String])
        /// How to ask for it, once.
        case asking([String])
        /// Then, while nothing is remembered: yab offers to get to know you.
        case knowing
    }

    /// Why the last try stopped, and for which agents.
    struct Trouble: Equatable {
        let clis: [String]
        let words: String
    }

    private var geminiChanges: AnyCancellable?

    init(status: AgentSetup.Status = AgentSetup.status(), consent: ProviderConsent = .shared) {
        self.consent = consent
        self.status = status
        geminiChanges = GeminiAccount.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            // Signed in after all (in Terminal, after Connect gave up): the
            // words saying it wasn't go (#373). Read once the change landed.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, GeminiAccount.shared.ready, self.trouble?.clis.contains("gemini") == true else { return }
                    self.trouble = nil
                }
            }
        }
        for cli in Self.clis {
            let seconds = Store.settings.double(forKey: "agents.used." + cli)
            if seconds > 0 { lastUse[cli] = Date(timeIntervalSince1970: seconds) }
        }
    }

    /// What people read, in every word about connecting, asking and
    /// limits: the plan they signed in with.
    nonisolated static func name(_ cli: String) -> String { plan(cli) }
    /// The tool Yab runs for it, only where a person types it or has it
    /// on this Mac already: a terminal, the skill and tools it was given.
    nonisolated static func tool(_ cli: String) -> String { (AgentPlan.of(cli) ?? .claude).tool }
    /// "Claude and ChatGPT", "Claude, ChatGPT, and Cursor".
    nonisolated static func names(_ clis: [String]) -> String { list(clis.map(name)) }
    /// Words joined as a sentence lists them.
    nonisolated static func list(_ words: [String], or: Bool = false) -> String {
        let word = or ? "or" : "and"
        guard words.count > 2 else { return words.joined(separator: " \(word) ") }
        return words.dropLast().joined(separator: ", ") + ", \(word) " + words.last!
    }
    /// Whether the agent gets Yab's skill and tools and is asked for Yab
    /// by name. Cursor runs inside Yab only: no skill, no How to Ask.
    nonisolated static func skilled(_ cli: String) -> Bool { AgentPlan.of(cli)?.skilled == true }
    /// Whose plan it signs in to.
    nonisolated static func plan(_ cli: String) -> String { (AgentPlan.of(cli) ?? .claude).name }
    nonisolated static func binary(_ cli: String, in found: Shell.Found?) -> String? { found?[keyPath: (AgentPlan.of(cli) ?? .claude).binary] }
    nonisolated static func install(_ cli: String) -> String { (AgentPlan.of(cli) ?? .claude).install }
    /// What yab runs to install it itself, or nil when there is no way
    /// here: Codex wants npm or Homebrew on the login shell's PATH.
    static func installer(_ cli: String, _ found: Shell.Found) -> String? {
        // A test world's stand-in (YAB_AGENT_INSTALLER), never a download.
        if Store.testing, let given = ProcessInfo.processInfo.environment["YAB_AGENT_INSTALLER"] { return given }
        guard cli == "codex" else { return install(cli) }
        let folders = (found.env["PATH"] ?? "").split(separator: ":").map(String.init)
        func has(_ tool: String) -> Bool { folders.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + tool) } }
        if has("npm") { return install(cli) }
        if has("brew") { return "brew install codex" }
        return nil
    }
    /// How a person names yab's skill to it: Claude Code makes a skill a
    /// command of its own, Codex takes it with a dollar sign.
    static func mention(_ cli: String) -> String { (cli == "codex" ? "$" : "/") + AgentSetup.skill }

    /// The words for each way a try stops.
    static let late = "Your shell took too long to answer."
    static let closed = "The sign-in tab was closed before you said yes."
    static let waited = "The sign-in waited ten minutes and stopped."
    static func gone(_ cli: String) -> String { "\(name(cli)) isn't set up on this Mac anymore." }
    static func refused(_ cli: String) -> String { "\(name(cli)) wasn't signed in." }
    /// macOS stopped the copy as it ran, or moved it to the Trash.
    static func blocked(_ cli: String) -> String { "macOS blocked \(tool(cli)). Reinstall it." }
    static func untaken(_ clis: [String]) -> String { "Yab couldn't add its tools for \(names(clis))." }

    /// When an install is slow enough to say so: two minutes, or less in a
    /// test world that says so.
    static var slowAfter: TimeInterval {
        guard Store.testing, let given = ProcessInfo.processInfo.environment["YAB_INSTALL_SLOW"].flatMap(Double.init) else { return 120 }
        return given
    }

    func installed(_ cli: String) -> Bool { Self.binary(cli, in: found) != nil }
    /// A removed or missing Gemini plan is offered only by Add Account.
    var showsGemini: Bool { GeminiAccount.shared.enabled && installed("gemini") }
    func connected(_ cli: String) -> Bool {
        consent.allows(cli)
    }
    var anyConnected: Bool { Self.clis.contains(where: connected) }
    var busy: Bool { working != nil || flow != nil }
    /// Yab has looked for the agents on this Mac.
    var ready: Bool { found != nil }
    /// The way in shows until an agent is connected, and while Connect runs,
    /// but not while a connected agent signs in again from Models.
    var arriving: Bool { (flow != nil && renewing == nil) || !anyConnected }

    /// Connected first, then installed, then the rest.
    var order: [String] {
        Self.clis.sorted { rank($0) < rank($1) }
    }

    private func rank(_ cli: String) -> Int { connected(cli) ? 0 : installed(cli) ? 1 : 2 }

    private var identityLook = 0

    /// Looked for afresh, so an agent installed since yab opened is seen,
    /// and whether each is signed in. Looking never runs an agent: macOS
    /// checks a binary as it runs, and an old copy it flags would look like
    /// Yab's doing. Only the buttons and tasks do.
    ///
    /// Once an agent is connected, in the environment a task on it runs in
    /// (AgentLaunch.environment: the login shell's PATH, an exported
    /// CLAUDE_CODE_OAUTH_TOKEN, the key you connected): the very
    /// Shell.Found the launcher's next task starts from, so "signed in"
    /// here is "a chat would start" there (#1687). Nothing connected, from
    /// files alone: nothing unconnected runs the login shell (Cortex).
    /// Only a person's ask (asked: ⌘J, words in a composer), Settings or
    /// a task looks; never the launch or a timer of its own.
    /// `find(login)` stands for Shell.find(fresh:, resolvingLogin: login);
    /// `fresh` false takes what a task just resolved. `readGemini` is
    /// Gemini's sign-in in that environment (GeminiAccount, its CLI asked).
    /// `whereTasksRun` false: a surface that shows by itself, nobody having
    /// acted (a bot site's notice), looks from files alone and never runs
    /// the login shell, nor replaces what a look where tasks run found
    /// (Cortex, fix/cortex-helper-tree e41bac1f).
    func look(fresh: Bool = true, whereTasksRun: Bool = true,
              find: ((_ login: Bool) async -> Shell.Found)? = nil,
              readStatus: () async -> AgentSetup.Status = { await AgentSetup.read() },
              plans: PlanAccounts? = nil,
              readIdentity: (PlanAccount, [String: String], Int) async -> (signedIn: Bool, email: String?, plan: String?) = {
                  await PlanAccounts.read($0, env: $1, revision: $2)
              },
              readGemini: ((Shell.Found, ProviderLaunchPermit?) async -> Bool?)? = nil) async {
        let find = find ?? { await Shell.find(fresh: fresh, resolvingLogin: $0) }
        let readGemini = readGemini ?? { found, permit in
            await GeminiAccount.shared.look(permit: permit, find: { _ in found })
            return GeminiAccount.shared.signedIn
        }
        guard whereTasksRun || !lookedInTerminal else { return }
        lastLook = Date()
        identityLook += 1
        let mine = identityLook
        let readingAttempt = attempt
        let terminal = whereTasksRun && AgentLaunch.needsTerminal(consent)
        let found = await find(terminal)
        guard identityLook == mine, attempt == readingAttempt else { return }
        self.found = found
        lookedInTerminal = terminal
        status = await readStatus()
        guard identityLook == mine, attempt == readingAttempt else { return }
        await project(found, whereTasksRun: whereTasksRun, mine: mine, readingAttempt: readingAttempt, plans: plans ?? PlanAccounts.shared,
                      readIdentity: readIdentity, readGemini: readGemini)
    }

    /// Each CLI's signed-in state from what `found` says, until a newer
    /// look or attempt begins, which leaves the rest to it.
    private func project(_ found: Shell.Found, whereTasksRun: Bool, mine: Int, readingAttempt: Int, plans: PlanAccounts,
                         readIdentity: (PlanAccount, [String: String], Int) async -> (signedIn: Bool, email: String?, plan: String?),
                         readGemini: (Shell.Found, ProviderLaunchPermit?) async -> Bool?) async {
        // The person chooses one provider; installed tools are not consent to use them.
        for cli in Self.clis {
            // The copy, account and environment a task would run on
            // (AgentLaunch.look, the launcher's resolution less secrets):
            // no copy, no task.
            guard let launch = AgentLaunch.look(cli, in: found, plans: plans) else { signedIn[cli] = nil; continue }
            if cli == "gemini" {
                // A notice reuses the last verified answer; only a person's
                // ask can execute the connected provider. Gemini's sign-in
                // is its CLI's to say, asked in the
                // environment its turns run in (Agents.launch gives them
                // this copy and found.env).
                let permit = whereTasksRun ? consent.permit(cli) : nil
                let said = permit != nil ? await readGemini(found, permit) : GeminiAccount.shared.signedIn
                guard identityLook == mine, attempt == readingAttempt else { return }
                signedIn[cli] = said
            } else if cli == "cursor" {
                // The launcher's own check (Agents.signedIn for Cursor), on
                // the same copy and environment; passive or unconnected,
                // only what it last said, nothing run.
                let permit = whereTasksRun ? consent.permit(cli) : nil
                let who = permit != nil ? await CursorRunner.identify(binary: launch.binary, env: launch.env, permit: permit)
                    : CursorRunner.identity(env: launch.env)
                guard identityLook == mine, attempt == readingAttempt else { return }
                if let permit, !permit.valid { continue }
                signedIn[cli] = who.signedIn
            } else if !AgentFixture.requested, AgentLaunch.byHarness(cli) {
                // A probe's stand-in Claude or Codex (YAB_AGENT_CLAUDE) is
                // signed in by its harness: the Mac running the probe may
                // have no account of its own (m4 has none, adhd the owner's),
                // and reading that one made a probe's chats depend on the Mac.
                // Gemini and Cursor keep their own looks above: those read
                // the stand-in itself, and Gemini's account hangs on it.
                signedIn[cli] = true
            } else {
                // Every account a task may start on, in the launcher's order,
                // each read in the environment its task runs in
                // (PlanAccounts.read applies PlanAccounts.environment, as
                // the launcher's env does). Dispatch can use an extra account
                // even when the usual CLI login is signed out (#1687).
                let accounts = plans.all(cli)
                let revisions = Dictionary(accounts.map { ($0.id, plans.identityRevision($0.id)) }, uniquingKeysWith: { first, _ in first })
                var available = false
                var heard: [(PlanAccount, Bool)] = []
                for account in accounts {
                    let who: (signedIn: Bool, email: String?, plan: String?)
                    if account.keyed {
                        who = (await AgentKey.hasSecret(account.id), nil, nil)
                    } else {
                        who = await readIdentity(account, found.env, revisions[account.id]!)
                    }
                    guard identityLook == mine, attempt == readingAttempt else { return }
                    available = available || who.signedIn
                    heard.append((account, who.signedIn))
                }
                // A logout, removal, or renewal during any of those reads
                // invalidates the whole projection, including earlier positives.
                guard plans.all(cli) == accounts,
                      accounts.allSatisfy({ plans.identityRevision($0.id) == revisions[$0.id] }) else { continue }
                // The launcher's pick (PlanAccounts.pick) skips an account
                // signed out: told what was just read, a task starts on the
                // account this found signed in, not on one it would have to
                // sign in to first.
                for (account, yes) in heard { plans.heard(account, signedIn: yes, revision: revisions[account.id]!) }
                signedIn[cli] = available
            }
        }
    }

    /// A verified login can live in an extra config folder.
    /// Invalidate an older passive negative before it can overwrite it.
    func didConnect(_ cli: String) {
        identityLook += 1
        signedIn[cli] = true
    }

    /// The last look was in the environment a task runs in.
    private(set) var lookedInTerminal = false

    /// Whether a task can run on a plan here: one signed in, or, before a
    /// look where tasks run (nothing looks at launch: only a person's ask,
    /// Settings or a task does), a connected one that files show installed
    /// or can't rule out (it may be on the login shell's PATH). Until then
    /// the task itself resolves it (AgentLaunch) and signs in if it must:
    /// Return never opens Settings for a chat that would run.
    func canRunTasks() -> Bool {
        if Self.clis.contains(where: { consent.allows($0) && signedIn[$0] == true }) { return true }
        return Self.clis.contains { cli in
            guard consent.allows(cli), signedIn[cli] == nil else { return false }
            if Self.binary(cli, in: found ?? Shell.cached) != nil { return true }
            return AgentLaunch.terminalCLIs.contains(cli) && !lookedInTerminal
        }
    }

    private var lastLook = Date.distantPast

    /// Where a person is asking or setting up now: a composer with the
    /// keys, Settings › AI. Only while one is, a "no" is looked at again,
    /// at most once a minute, so a sign-in in Terminal shows without a
    /// restart; nothing looks on a timer of its own otherwise.
    private(set) var showing: Set<String> = []

    func showing(_ surface: String, _ shown: Bool) {
        if shown { showing.insert(surface) } else { showing.remove(surface) }
    }

    /// A person asks: ⌘J, or words in a composer. The first look where
    /// tasks run happens now (not at launch), and a "no" is looked at
    /// again once a minute at most, so Return knows by the time it comes.
    func asked() {
        guard !lookedInTerminal || (!canRunTasks() && Date().timeIntervalSince(lastLook) > relookAfter) else { return }
        lastLook = Date()
        Task { await again(fresh: true) }
    }

    /// How long a "no" stands before an ask or an open surface looks again.
    var relookAfter: TimeInterval = 60
    /// What looking again runs; a test gives its own world's look.
    var lookAgain: ((_ fresh: Bool) async -> Void)?

    private func again(fresh: Bool) async {
        if let lookAgain { await lookAgain(fresh) } else { await look(fresh: fresh) }
    }

    /// A task resolved where it runs (Agents.launch): readiness projects
    /// that same answer if nothing has looked there yet, with no second
    /// login shell (the task's is cached).
    func taskResolved() {
        guard !lookedInTerminal, AgentLaunch.needsTerminal(consent) else { return }
        lastLook = Date()
        Task { await again(fresh: false) }
    }

    /// Agents.ready: canRunTasks, with a no looked at again at most once a
    /// minute while a composer or Settings is open.
    func canTakeTasks() -> Bool {
        let can = canRunTasks()
        if !can, !showing.isEmpty, Date().timeIntervalSince(lastLook) > relookAfter {
            lastLook = Date()
            Task { await again(fresh: true) }
        }
        return can
    }

    func reread() {
        Task { status = await AgentSetup.read() }
    }

    // MARK: - connecting

    /// Each one signed in to its plan if it isn't, in a tab of yours; then
    /// yab put where it looks, with no more to see than the tick; then how
    /// to ask for it. Every step has its state from the moment it starts,
    /// the first one before anything runs, so a second press is nothing.
    /// Cancelled or turned down, nothing is written.
    /// The provider row is a single choice even when several tools are installed.
    func selectProvider(_ cli: String) {
        guard Self.clis.contains(cli), !busy else { return }
        picks = [cli]
        clearFailure()
    }

    func connect(_ clis: [String], _ browser: Browser, account: String? = nil) {
        guard !clis.isEmpty, !busy else { return }
        if clis == ["gemini"], GeminiAccount.shared.choice == nil, !AgentFixture.requested {
            chooseGemini(browser)
            return
        }
        begin(clis, browser, account: account)
    }

    func chooseGemini(_ browser: Browser) {
        guard !busy else { return }
        GeminiChoices.shared.switching = connected("gemini") && GeminiAccount.shared.ready
        GeminiAccount.shared.choice = nil
        consent.beginConnection("gemini")
        GeminiChoices.shared.chosen = nil
        GeminiChoices.shared.showing = true
    }

    /// Gemini and Cursor have one profile. Adding them again reconnects
    /// that profile through setup rather than creating a second account.
    func addAccount(_ cli: String, _ browser: Browser) {
        if !installed(cli) { install(cli, browser) }
        else if cli == "gemini" { chooseGemini(browser) }
        else if !connected(cli) || cli == "cursor" { connect([cli], browser) }
        else { PlanAccounts.shared.add(cli, browser) }
    }

    /// Straight into `.preparing`, from a press or from an install that
    /// has just finished, never through nil.
    private func begin(_ clis: [String], _ browser: Browser, account: String? = nil) {
        attempt += 1
        consent.cancelConnections()
        for cli in clis { consent.beginConnection(cli) }
        guard let permits = consent.connectionPermits(clis) else { return }
        let mine = attempt
        trouble = nil
        page = nil
        slow = false
        installByHand = false
        // Installed for a key: on with the key, never a plan's sign-in.
        if let pending = pendingKey, clis == [pending.cli] {
            pendingKey = nil
            renewing = nil
            keying = pending.cli
            flow = .preparing(clis)
            guard let permit = permits[pending.cli] else { return }
            Task { await keyed(pending.cli, pending.key, browser, mine, permit: permit) }
            return
        }
        pendingKey = nil
        keying = nil
        renewing = clis.allSatisfy { connected($0) } ? (account ?? clis.first) : nil
        flow = .preparing(clis)
        Task { await connecting(clis, browser, mine, permits: permits) }
    }

    /// Use an API Key: the agent installed if it isn't, the key checked
    /// once with its provider, kept (Claude's in Yab's keychain item,
    /// Codex's through its own login), and then the rest of Connect as
    /// after a sign-in. A key the provider turns down is said on the way
    /// in and nothing is kept.
    func connect(_ cli: String, key: String, _ browser: Browser) {
        guard !busy, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard cli == "claude" || cli == "codex" else { return }
        pendingKey = (cli, key)
        keying = cli
        if installed(cli) { begin([cli], browser) } else { install(cli, browser) }
    }

    private func keyed(_ cli: String, _ key: String, _ browser: Browser, _ mine: Int, permit: ProviderLaunchPermit) async {
        guard attempt == mine, permit.valid else { return }
        await consent.settleDisconnects()
        guard attempt == mine, permit.valid else { return }
        var found = await Shell.find(fresh: true)
        guard attempt == mine, permit.valid else { return }
        self.found = found
        if found.late { return fail([cli], Self.late, browser) }
        guard let binary = Self.binary(cli, in: found) else { return fail([cli], Self.gone(cli), browser) }
        let checked = await AgentKey.check(cli, key, permit: permit)
        guard attempt == mine, permit.valid else { return }
        switch checked {
        case .refused: return fail([cli], AgentKey.refused(cli), browser)
        case .unreachable: return fail([cli], AgentKey.unreachable(cli), browser)
        case .taken: break
        }
        guard attempt == mine, permit.valid else { return }
        if cli == "codex" {
            let signedIn = await AgentKey.codexLogin(binary: binary, key: key, env: found.env, permit: permit)
            guard attempt == mine, permit.valid else { return }
            guard signedIn else { return fail([cli], AgentKey.unsaved(cli), browser) }
        } else {
            AgentKey.keep(claude: key)
            found.env = AgentKey.apply(found.env)
            let applied = AgentKey.apply(Shell.cached?.env ?? found.env)
            Shell.cached?.env = applied
        }
        guard attempt == mine, permit.valid else { return }
        signedIn[cli] = true
        await finishing([cli], found, browser, mine, permits: [cli: permit])
    }

    /// Remove API Key: Claude's key out of the keychain and out of every
    /// env from now on; Codex logged out, only when a key is what it holds.
    /// A plan signed in underneath takes over again.
    func removeKey(_ cli: String) {
        disconnectWork = nil
        working = cli
        Task {
            let found = await Shell.find()
            if cli == "codex", let binary = Self.binary(cli, in: found) {
                await AgentKey.codexLogout(binary: binary, env: found.env)
            } else if cli == "claude" {
                AgentKey.keep(claude: nil)
                let applied = AgentKey.apply(Shell.cached?.env ?? found.env)
                Shell.cached?.env = applied
            }
            working = nil
            await look()
            if let found = self.found { await PlanAccounts.shared.look(found) }
        }
    }

    private func connecting(_ clis: [String], _ browser: Browser, _ mine: Int, permits: [String: ProviderLaunchPermit]) async {
        @MainActor func current() -> Bool { attempt == mine && permits.count == clis.count && permits.values.allSatisfy { $0.valid } }
        guard current() else { return }
        await consent.settleDisconnects()
        guard current() else { return }
        let found = await Shell.find(fresh: true)
        guard current() else { return }
        self.found = found
        if let gone = clis.first(where: { Self.binary($0, in: found) == nil }) {
            return fail(clis, found.late ? Self.late : Self.gone(gone), browser)
        }
        for cli in clis {
            guard current(), let permit = permits[cli], let binary = Self.binary(cli, in: found) else { return }
            if cli == "gemini" {
                let account = GeminiAccount.shared
                account.enabled = true
                await account.look(fresh: true, permit: permit)
                guard current() else { return }
                if !account.ready || account.choice.map({ $0.source != .mac }) == true {
                    flow = .signingIn(cli)
                    page = .yab
                    account.signIn(permit: permit, in: browser)
                    // GeminiAccount ends its own wait by the clock; this one
                    // too, a beat later, so Connect never turns on forever (#373).
                    while current(), account.waiting != nil, !account.ready,
                          Date() < (account.waitingUntil ?? Date()).addingTimeInterval(30) {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    guard current() else { return }
                    page = nil
                    if !account.ready, account.waiting != nil { account.cancel() }
                    guard account.ready else {
                        return fail(clis, account.trouble ?? GeminiAccount.gaveUp(.signingIn, said: account.lastSaid, limit: GeminiAccount.waitLimit), browser)
                    }
                }
                account.choice = nil
                signedIn[cli] = true
                continue
            }
            let plans = PlanAccounts.shared
            let previous = plans.account(renewing).flatMap { $0.cli == cli ? $0 : nil } ?? plans.account(cli) ?? PlanAccount(id: cli, cli: cli)
            // A broken CLI is not a signed-out account. Surface its launch
            // error before Connect opens an unrelated sign-in loop.
            if cli == "claude" {
                let ran = await Shell.timed(binary, ["auth", "status"], env: plans.env(previous, base: found.env), permit: permit, captureErrors: true)
                guard current() else { return }
                if ran.late || ![0, 1].contains(ran.code) {
                    return fail(clis, AgentCopies.launchFailure(Self.name(cli), binary: binary,
                        env: AgentCopies.environment(for: binary, base: plans.env(previous, base: found.env)),
                        reason: ran.late ? "didn't respond while checking its CLI sign-in." : "couldn't check its CLI sign-in (exit code \(ran.code)).",
                        diagnostic: ran.diagnostic), browser)
                }
            }
            await plans.remember(previous, binary: binary, base: found.env, permit: permit)
            guard current() else { return }
            if Shell.blocked(binary) { return fail(clis, Self.blocked(cli), browser) }
            let now = !plans.signedOut.contains(previous.id)
            if now { didConnect(cli); continue }
            if previous.usual { signedIn[cli] = false }
            var candidate = plans.prepareSignIn(cli, replacing: previous.id)
            let env = plans.env(candidate, base: found.env)
            flow = .signingIn(cli)
            page = .opening
            // Ten minutes at most (YAB_SIGNIN_LIMIT in a test world).
            let end = await Agents.shared.connect(cli, binary: binary, env: env, in: browser, permit: permit) { [weak self] place in
                guard let self, current(), self.flow == .signingIn(cli) else { return }
                self.page = place
            }
            guard current() else { return }
            if end != .signedIn { await plans.discardSignIn(candidate, binary: binary, base: found.env, permit: permit) }
            guard current() else { return }
            page = nil
            if end == .canceled {
                // Stopped from somewhere that didn't come through cancel().
                flow = nil
                renewing = nil
                return
            }
            // Back to where it was asked from: Settings, or the welcome.
            Self.bringBack()
            if end != .signedIn, Shell.blocked(binary) { return fail(clis, Self.blocked(cli), browser) }
            switch end {
            case .closed: return fail(clis, Self.closed, browser)
            case .timedOut: return fail(clis, Self.waited, browser)
            case .refused, .canceled: return fail(clis, Self.refused(cli), browser)
            case .signedIn:
                // The tab has closed: the welcome comes back at once, on
                // this state, not on the tick.
                flow = .finishing(clis)
                let who = await PlanAccounts.identify(candidate, binary: binary, env: env, permit: permit)
                guard current() else { return }
                guard who.signedIn else {
                    await plans.discardSignIn(candidate, binary: binary, base: found.env, permit: permit)
                    if current() { fail(clis, Self.refused(cli), browser) }
                    return
                }
                candidate.email = who.email
                candidate.plan = who.plan
                _ = plans.acceptSignIn(candidate, replacing: previous.id)
                // A verified login in a separate folder is runnable too.
                didConnect(cli)
            }
        }
        await finishing(clis, found, browser, mine, permits: permits)
    }

    /// Signed in, by a plan or a key: Yab's skill, tools and command put in
    /// place, then the tick and How to Ask.
    private func finishing(_ clis: [String], _ found: Shell.Found, _ browser: Browser, _ mine: Int,
                           permits: [String: ProviderLaunchPermit]) async {
        guard attempt == mine else { return }
        guard permits.count == clis.count, permits.values.allSatisfy({ $0.valid }) else { return }
        flow = .finishing(clis)
        browser.prefs.bench = true
        let troubles = await AgentSetup.setUp(found, only: Set(["command"] + clis), permits: permits)
        guard attempt == mine, permits.values.allSatisfy({ $0.valid }) else { return }
        let after = await Shell.find(fresh: true)
        guard attempt == mine, permits.values.allSatisfy({ $0.valid }) else { return }
        self.found = after
        let read = await AgentSetup.read()
        guard attempt == mine, permits.values.allSatisfy({ $0.valid }) else { return }
        status = read
        if let cli = clis.first(where: { Self.binary($0, in: found).map(Shell.blocked) == true }) {
            return fail(clis, Self.blocked(cli), browser)
        }
        if let first = troubles.first { return fail(clis, first, browser) }
        let done = clis.filter { cli in
            cli == "gemini" ? GeminiAccount.shared.ready : AgentPlan.of(cli).map { status[keyPath: $0.connected] } ?? false
        }
        guard !done.isEmpty else { return fail(clis, Self.untaken(clis), browser) }
        for cli in done { consent.grant(cli); ConsentAudit.record("provider.connect") }
        let granted = done.compactMap { consent.permit($0) }
        if keying != nil {
            await PlanAccounts.shared.look(after)
            guard attempt == mine, granted.allSatisfy({ $0.valid }) else { return }
            keying = nil
            keyFor = nil
        }
        if let cli = done.first, done.count == 1, renewing == nil || picks == Set(done) {
            ModelDefaults.shared.useProvider(cli)
        }
        picks = []
        if renewing != nil {
            // Signed in again: the row goes back to its plan, quietly.
            await PlanAccounts.shared.look(after)
            guard attempt == mine, granted.allSatisfy({ $0.valid }) else { return }
            renewing = nil
            flow = nil
            return
        }
        flow = .landed(done)
        tried = nil
        try? await Task.sleep(for: .seconds(0.9))
        guard attempt == mine, granted.allSatisfy({ $0.valid }), flow == .landed(done) else { return }
        // How to Ask is for the agents asked for Yab by name; a plan that
        // only runs inside Yab goes back to its row with the tick.
        let askable = done.filter(Self.skilled)
        if askable.isEmpty {
            await PlanAccounts.shared.look(after)
            guard attempt == mine, granted.allSatisfy({ $0.valid }) else { return }
            flow = nil
        } else {
            flow = .asking(askable)
        }
    }

    /// Stopped: back to the page, with why beside the button. Only when
    /// neither Settings nor the welcome is up to show it, in the corner too.
    /// The welcome's failure words taken back: another agent chosen.
    func clearFailure() {
        if trouble != nil { trouble = nil }
    }

    private func fail(_ clis: [String], _ words: String, _ browser: Browser) {
        flow = nil
        page = nil
        renewing = nil
        keying = nil
        pendingKey = nil
        slow = false
        trouble = Trouble(clis: clis, words: words)
        if SettingsWindow.shared.window?.isVisible != true, !browser.welcoming {
            browser.announce(words, mark: "exclamationmark.triangle")
        }
    }

    /// Back to where Connect was asked from: Settings, or the window.
    private static func bringBack() {
        if let settings = SettingsWindow.shared.window, settings.isVisible { settings.makeKeyAndOrderFront(nil) }
        else { Links.window?.makeKeyAndOrderFront(nil) }
        NSApp.activate()
    }

    /// Yab installs it itself when it can, and connects it the moment it is
    /// there; else the command copied and Terminal opened, and the way in
    /// waits for it.
    func install(_ cli: String, _ browser: Browser) {
        guard !busy else { return }
        attempt += 1
        let mine = attempt
        trouble = nil
        page = nil
        renewing = nil
        slow = false
        installByHand = false
        flow = .installing(cli)
        Task { await installing(cli, browser, mine) }
    }

    private func installing(_ cli: String, _ browser: Browser, _ mine: Int) async {
        guard attempt == mine else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.slowAfter))
            guard let self, self.attempt == mine, self.flow == .installing(cli), !self.installByHand else { return }
            self.slow = true
        }
        let found = await Shell.find(fresh: true)
        guard attempt == mine else { return }
        self.found = found
        // Here already, pressed while Yab was still looking: connect it.
        if Self.binary(cli, in: found) != nil {
            picks = [cli]
            return begin([cli], browser)
        }
        // Its own installer, run here: Claude Code's script puts it in
        // ~/.local/bin with no password; Codex comes through npm or
        // Homebrew when either is here.
        if cli != "gemini", AgentSetup.mayInstall, let command = Self.installer(cli, found) {
            let run = InstallRun()
            installer = run
            let (code, _) = await Shell.run("/bin/bash", ["-c", command], env: found.env, limit: 600, started: { run.keep($0) })
            if installer === run { installer = nil }
            guard attempt == mine else { return }
            let after = await Shell.find(fresh: true)
            guard attempt == mine else { return }
            self.found = after
            if code == 0, Self.binary(cli, in: after) != nil {
                picks = [cli]
                if cli == "gemini", GeminiAccount.shared.choice == nil, !AgentFixture.requested {
                    flow = nil
                    installByHand = false
                    chooseGemini(browser)
                    return
                }
                return begin([cli], browser)
            }
        }
        // Not from here: the command to paste, and a look every couple of
        // seconds until it is there.
        installByHand = true
        slow = false
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.install(cli), forType: .string)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                           configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        var beat = 0
        while attempt == mine {
            try? await Task.sleep(for: .seconds(2))
            guard attempt == mine else { return }
            beat += 1
            // The usual places, a file each, every two seconds; a fresh
            // login shell, a second or two of CPU, only every ten.
            guard Self.onDisk(cli) || beat % 5 == 0 else { continue }
            let found = await Shell.find(fresh: true)
            guard attempt == mine else { return }
            self.found = found
            if Self.binary(cli, in: found) != nil {
                picks = [cli]
                if cli == "gemini", GeminiAccount.shared.choice == nil, !AgentFixture.requested {
                    flow = nil
                    installByHand = false
                    chooseGemini(browser)
                    return
                }
                return begin([cli], browser)
            }
        }
    }

    /// Where its installers put it, looked at without a shell.
    static func onDisk(_ cli: String) -> Bool {
        let home = AgentSetup.home.path
        let cli = cli == "gemini" ? "agy" : cli
        return ["\(home)/.local/bin/\(cli)", "/opt/homebrew/bin/\(cli)", "/usr/local/bin/\(cli)", "\(home)/.claude/local/\(cli)"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Stops what runs, the sign-in's CLI or the installer and what it
    /// started, and goes back to the page as it was before the press.
    func cancel() {
        attempt += 1
        GeminiAccount.shared.choice = nil
        GeminiChoices.shared.showing = false
        consent.cancelConnections()
        if let work = disconnectWork { endDisconnectWork(work) }
        if case .signingIn(let cli) = flow {
            if cli == "gemini" { GeminiAccount.shared.cancel() }
            else { Agents.shared.cancelConnect(cli, privately: false) }
        }
        installer?.stop()
        installer = nil
        flow = nil
        page = nil
        renewing = nil
        keying = nil
        pendingKey = nil
        slow = false
        installByHand = false
    }

    /// The sign-in in front again: its tab, or its page opened again in
    /// the browser Codex used.
    func showSignIn() {
        guard case .signingIn(let cli) = flow else { return }
        if cli == "gemini" { GeminiAccount.shared.showSignIn() }
        else { Agents.shared.showSignIn(cli) }
    }

    /// Done with How to Ask: yab's offer to get to know you, while it
    /// knows nothing, may remember, and isn't at it already; else the page.
    func finish(_ prefs: Preferences) {
        let offer = { () -> Bool in
            guard case .asking(let clis) = self.flow else { return false }
            // Cursor connects a plan inside Yab, not an external agent for
            // background memory work. Keep that offer for its existing plans.
            return clis.contains(where: Self.skilled)
        }()
        flow = offer && prefs.agentsRemember && Memory.empty && knowingNow == nil ? .knowing : nil
    }

    /// Get to Know Me: yab's own agent looks you up, once, out of sight;
    /// the run already under way if there is one. The page shows how far
    /// it has got in Memory's row.
    func getToKnow() {
        ContextConsent.request()
        switch flow {
        case .landed, .asking, .knowing: flow = nil
        default: break
        }
    }

    func stopKnowing() {
        if let id = knowingNow?.id ?? knowing { _ = Agents.shared.stop(id) }
        knowing = nil
    }

    /// Get to Know Me's run while it is at work, whoever started it.
    var knowingNow: Agents.Session? {
        let agents = Agents.shared
        if let session = agents.session(knowing), session.knowing, !session.quiet, session.state.live { return session }
        return agents.sessions.first { $0.knowing && !$0.quiet && $0.parent == nil && $0.state.live }
    }

    /// General suggestions do not authorize recurring signed-in site reads.
    /// The explicit "Keep an eye on things for me" action owns that grant.
    func turnOnSuggestions(_ prefs: Preferences) {
        guard anyConnected else { return }
        prefs.bench = true

        Hints.shared.suggesting = true
    }

    func showHowToAsk() {
        let done = Self.clis.filter { connected($0) && Self.skilled($0) }
        guard !done.isEmpty else { return }
        tried = nil
        flow = .asking(done)
    }

    func disconnect(_ clis: [String], _ browser: Browser) {
        guard !clis.isEmpty else { return }
        if clis.contains("gemini") {
            GeminiChoices.shared.showing = false
            GeminiAccount.shared.choice = nil
            switch flow {
            case .preparing(let providers), .finishing(let providers), .landed(let providers), .asking(let providers):
                if providers.contains("gemini") { cancel() }
            case .installing("gemini"), .signingIn("gemini"): cancel()
            default: break
            }
            GeminiAccount.shared.cancel()
            GeminiAccount.shared.enabled = false
        }
        attempt += 1
        for cli in clis { consent.revoke(cli); Agents.shared.revokeProvider(cli) }
        if clis.contains("claude") { LocalAgentSetupPermit.revokeClaude() }
        let mine = attempt
        let disconnects = Dictionary(uniqueKeysWithValues: clis.compactMap { cli in consent.disconnectPermit(cli).map { (cli, $0) } })
        guard disconnects.count == clis.count else { return }
        let cleanupName = clis.count == 1 ? clis[0] : "all"
        let work = beginDisconnectWork(cleanupName)
        Task {
            defer {
                for permit in disconnects.values { permit.revoke() }
                endDisconnectWork(work)
            }
            let found = await Shell.find()
            guard attempt == mine, disconnects.values.allSatisfy({ $0.valid }) else { return }
            // The command goes with the last agent.
            let left = Self.clis.filter { connected($0) && !clis.contains($0) }
            await AgentSetup.remove(found, only: Set(clis + (left.isEmpty ? ["command"] : [])), disconnects: disconnects)
            guard attempt == mine, disconnects.values.allSatisfy({ $0.valid }) else { return }
            // A key Yab connected goes with it; a plan's sign-in stays the CLI's.
            let keyed = clis.filter { AgentKey.keyed($0) }
            for cli in keyed {
                if cli == "claude" {
                    _ = disconnects[cli]?.commit {
                        AgentKey.keep(claude: nil)
                        let applied = AgentKey.apply(Shell.cached?.env ?? found.env)
                        Shell.cached?.env = applied
                    }
                } else if let binary = Self.binary(cli, in: found) {
                    await AgentKey.codexLogout(binary: binary, env: found.env, disconnect: disconnects[cli])
                    guard attempt == mine, disconnects.values.allSatisfy({ $0.valid }) else { return }
                }
            }
            let read = await AgentSetup.read()
            guard attempt == mine, disconnects.values.allSatisfy({ $0.valid }) else { return }
            status = read
            if !keyed.isEmpty {
                await look()
                guard attempt == mine, disconnects.values.allSatisfy({ $0.valid }) else { return }
            }
            if !anyConnected { picks = [] }
        }
    }

    // MARK: - the bench

    /// What the last addkey said: "" when the key went in.
    private var benchKeyTrouble = ""

    /// `./bench ui agents`: connect, connect:CLI, install:CLI, cancel, ask
    /// (How to Ask), used:CLI (an agent opening a tab), finish (on to the
    /// offer to get to know you), know, suggest (Daily Suggestions' Turn On),
    /// stopknow, notnow, disconnect, show-signin, usekey:CLI (Use an API Key's
    /// field; usekey: shuts it), key:CLI (connect with YAB_AGENT_KEY),
    /// removekey:CLI,
    /// close-signin (the sign-in tab closed as a person would), add:CLI and
    /// cancel-add (Models' Add Account); and where it all stands. Test runs
    /// only.
    func bench(_ command: String, browser: Browser) -> [String: Any] {
        let accounts = PlanAccounts.shared
        switch command {
        case "gemini:idle", "gemini:checking", "gemini:signing-in", "gemini:landed":
            guard Store.testing else { break }
            picks = ["gemini"]
            page = command == "gemini:signing-in" ? .yab : nil
            switch command {
            case "gemini:checking": flow = .preparing(["gemini"])
            case "gemini:signing-in": flow = .signingIn("gemini")
            case "gemini:landed": flow = .landed(["gemini"])
            default: flow = nil
            }
        case "providers-unknown":
            guard Store.testing else { break }
            found = nil
            signedIn = [:]
        case "providers-known":
            guard Store.testing else { break }
            found = Shell.Found(claude: "/fixture/claude", codex: "/fixture/codex", env: [:])
            found?.gemini = "/fixture/agy"
            signedIn = ["claude": true, "codex": false, "gemini": true]
        case "connect": connect(Self.clis.filter { picks.contains($0) && installed($0) }, browser)
        case "cancel": cancel()
        case "ask": showHowToAsk()
        case "finish": finish(browser.prefs)
        case "know": getToKnow()
        case "suggest": turnOnSuggestions(browser.prefs)
        case "stopknow": stopKnowing()
        // The offer to get to know you, turned down (KnowStep's Not Now).
        case "notnow": if case .knowing = flow { flow = nil }
        case "disconnect": disconnect(Self.clis.filter { connected($0) }, browser)
        case "cancel-add": accounts.cancelAdding()
        // Which copies of the agents it found, looked for again.
        case "find": Task { await look() }
        case "show-signin":
            if let cli = accounts.adding, flow == nil { accounts.showSignIn(cli) } else { showSignIn() }
        case "close-signin":
            let tab: Tab? = {
                if case .signingIn(let cli) = flow { return Agents.shared.signInTab(cli) }
                return accounts.adding.flatMap { Agents.shared.signInTab($0, privately: true) }
            }()
            if let tab {
                let holder = BrowserWindows.shared.browsers.first { $0.tabs.contains { $0.id == tab.id } } ?? browser
                holder.close(tab)
            }
        default:
            if command.hasPrefix("select:") { selectProvider(String(command.dropFirst(7))) }
            if command.hasPrefix("install:") { install(String(command.dropFirst(8)), browser) }
            if command.hasPrefix("connect:") { connect([String(command.dropFirst(8))], browser) }
            if command.hasPrefix("used:") { used(by: String(command.dropFirst(5))) }
            if command.hasPrefix("add:") { accounts.add(String(command.dropFirst(4)), browser) }
            // Use an API Key's field open for an agent, or shut.
            if command.hasPrefix("usekey:") { keyFor = String(command.dropFirst(7)).nilIfEmpty }
            // Connect with the key a test world names (YAB_AGENT_KEY).
            if command.hasPrefix("key:") {
                connect(String(command.dropFirst(4)), key: ProcessInfo.processInfo.environment["YAB_AGENT_KEY"] ?? "", browser)
            }
            if command.hasPrefix("removekey:") { removeKey(String(command.dropFirst(10))) }
            // Models' own keys: addkey:CLI:KEY, keypage:PROVIDER (keypage:
            // shuts it), ranout:ID, movekey:ID:STEP, dropkey:ID,
            // openrouter:KEY.
            let parts = command.split(separator: ":", maxSplits: 2).map(String.init)
            switch (parts.first ?? "", parts.count) {
            case ("addkey", 3): Task { benchKeyTrouble = await accounts.addKey(parts[1], parts[2]) ?? "" }
            case ("keypage", _): APIKeys.shared.page = parts.count > 1 ? APIKeys.Provider(rawValue: parts[1]).map { APIKeys.Page(provider: $0) } : nil
            case ("ranout", 2): accounts.ranOut(parts[1])
            case ("movekey", 3): accounts.move(parts[1], by: Int(parts[2]) ?? 0)
            case ("dropkey", 2): accounts.remove(parts[1])
            case ("openrouter", 2):
                let keys = APIKeys.shared
                Task { benchKeyTrouble = await keys.take(parts[1], on: APIKeys.Page(provider: .openrouter), browser) ?? "" }
            default: break
            }
        }
        let place: String = {
            switch page {
            case .opening: return "opening"
            case .yab: return "yab"
            case .browser(let name): return "browser:" + (name ?? "")
            case nil: return ""
            }
        }()
        let step: String = {
            switch accounts.step {
            case .opening: return "opening"
            case .yab: return "yab"
            case .browser(let name): return "browser:" + (name ?? "")
            case .checking: return "checking"
            case nil: return ""
            }
        }()
        return ["flow": flow.map { "\($0)" } ?? "page", "claude": status.claude, "codex": status.codex,
                "cursor": status.cursor, "gemini": connected("gemini"), "geminiRow": showsGemini, "providers": Self.clis, "selectedProviders": Array(picks).sorted(), "arriving": arriving, "command": status.command, "signedIn": signedIn.mapValues { $0 },
                "lookedInTerminal": lookedInTerminal,
                "found": [found?.claude ?? "", found?.codex ?? ""],
                "page": place, "trouble": trouble?.words ?? "", "renewing": renewing ?? "", "slow": slow,
                "knowing": knowingNow?.id ?? "", "byHand": installByHand,
                "adding": accounts.adding ?? "", "addStep": step, "addTrouble": accounts.trouble ?? "",
                "keyFor": keyFor ?? "", "keying": keying ?? "", "keyed": Self.clis.filter { AgentKey.keyed($0) },
                "envKey": Shell.cached?.env[AgentKey.anthropic] != nil,
                // Each agent's accounts in order, which one a task starts
                // on, and the key its env would hand that one.
                "accounts": Dictionary(uniqueKeysWithValues: ["claude", "codex"].map { cli in
                    (cli, accounts.all(cli).map { ["id": $0.id, "tail": $0.tail ?? "", "out": accounts.out($0.id)] as [String: Any] })
                }),
                "picks": Dictionary(uniqueKeysWithValues: ["claude", "codex"].map { cli in (cli, accounts.pick(cli)?.id ?? "") }),
                "pickKey": (accounts.env(accounts.pick("claude"), base: Shell.cached?.env ?? [:])[AgentKey.anthropic]).map(AgentKey.tail) ?? "",
                "keyTrouble": benchKeyTrouble, "keyPage": APIKeys.shared.page?.provider.rawValue ?? "",
                "openRouter": APIKeys.shared.openRouter.compactMap { OpenRouterKey.key($0).map(AgentKey.tail) }]
    }

    // MARK: - use

    /// An agent opened a tab of its own: when, kept, and on How to Ask,
    /// that it worked.
    func used(by client: String) {
        let lower = client.lowercased()
        guard let cli = lower.contains("codex") ? "codex" : lower.contains("claude") ? "claude" : nil else { return }
        let now = Date()
        lastUse[cli] = now
        Store.settings.set(now.timeIntervalSince1970, forKey: "agents.used." + cli)
        if case .asking(let clis) = flow, clis.contains(cli), tried == nil { tried = cli }
    }

    /// "just now", "12m ago", "3h ago", "yesterday", "4d ago".
    nonisolated static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        case ..<172_800: return "yesterday"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}

/// An installer Shell.run started off the main thread, kept so Cancel can
/// stop it from the main one, and everything it started with it: a curl
/// piped into a shell outlives its parent otherwise.
final class InstallRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    /// As it starts, on Shell.run's queue. Stopped already: it goes at once.
    func keep(_ process: Process) {
        let late = lock.withLock { () -> Bool in
            if stopped { return true }
            self.process = process
            return false
        }
        if late { Shell.end(process, grace: 2) }
    }

    func stop() {
        let process = lock.withLock { () -> Process? in
            stopped = true
            defer { self.process = nil }
            return self.process
        }
        guard let process else { return }
        Shell.end(process, grace: 2)
    }
}
