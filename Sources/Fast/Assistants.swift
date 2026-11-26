import Foundation
import Security

// Assistants in the cloud (docs/assistants.md): ChatGPT, Claude.ai, Grok and
// the like, linked to this Mac with a code typed into Yab, use it as their
// browser through the server's /mcp. What the user let each one have is kept
// here. Answers from the person's other devices travel in sealed Sync.
//
// An assistant is an agent like any other once its call reaches the bench,
// with less: the user's tabs and its own, new ones in its own space, none of
// the user's memory, files or Mac, and every send, payment or deletion asked
// first.

extension AgentAsking: Codable {}

/// One assistant the user said yes to, and what it may do.
struct AssistantGrant: Codable, Identifiable, Equatable {
    /// This Mac's id for it, the one the server knows it by.
    let id: String
    /// What the user calls it: ChatGPT, Claude, Grok.
    var name: String
    /// What it called itself when it asked (OAuth client_name).
    var client: String
    /// The space its tabs open in, signed in as that space is.
    var space: UUID?
    /// Only an explicit choice widens access. Missing in older saved grants.
    var allSpaces: Bool? = nil
    /// Ask or Auto; Bypass only when the user picked it for this one.
    var mode: AgentAsking = .auto
    /// Mail tools (search, read, draft, send after a yes).
    var mail = false
    /// Sign-in codes from Messages.
    var messages = false
    /// Saved cards and addresses filled in, after a yes.
    var cards = false
    /// Sites it may never open, as registrable domains.
    var never: [String] = []
    /// A site the person explicitly allowed after a broad Never rule (for
    /// example, irs.gov while gov remains guarded). Exact sites only.
    var allowedSites: [String]? = nil
    /// When not empty, the only sites it may open.
    var only: [String] = []
    var paused = false
    let made: Date
    var used: Date?

    /// Nil is the explicit All spaces menu choice, never a legacy default.
    func selectedSpace(in spaces: [Space]) -> UUID? {
        if allSpaces == true { return nil }
        return spaces.first { $0.id == space }?.id ?? spaces.first?.id
    }

    mutating func selectSpace(_ choice: UUID?) {
        allSpaces = choice == nil
        if let choice { space = choice }
    }

    func spaceName(in spaces: [Space]) -> String {
        if allSpaces == true { return "All spaces" }
        return spaces.first { $0.id == selectedSpace(in: spaces) }?.name ?? ""
    }
}

/// An assistant asking for more than it has (request_access), waiting in
/// Settings for the user.
struct AssistantRequest: Codable, Equatable {
    var id: String = UUID().uuidString.lowercased()
    let assistant: String
    /// mail, messages, cards or site.
    let what: String
    var site: String?
    var reason: String
    let at: Date
}

@MainActor
final class Assistants: ObservableObject {
    static let shared = Assistants()

    @Published private(set) var grants: [AssistantGrant] = []
    /// What assistants asked for, newest last; not kept past a restart.
    @Published private(set) var requests: [AssistantRequest] = []

    private var store: UserDefaults { Store.settings }

    private init() {
        if let data = store.data(forKey: "assistants.grants"), let kept = try? JSONDecoder().decode([AssistantGrant].self, from: data) {
            grants = kept.map { old in
                var grant = old
                if grant.mode == .bypass { grant.mode = .auto }
                return grant
            }
        }
    }

    func grant(_ id: String?) -> AssistantGrant? {
        guard let id else { return nil }
        return grants.first { $0.id == id }
    }

    func keep(_ grant: AssistantGrant) {
        if let at = grants.firstIndex(where: { $0.id == grant.id }) { grants[at] = grant } else { grants.append(grant) }
        save()
    }

    func update(_ id: String, _ change: (inout AssistantGrant) -> Void) {
        guard let at = grants.firstIndex(where: { $0.id == id }) else { return }
        var grant = grants[at]
        change(&grant)
        guard grant != grants[at] else { return }
        grants[at] = grant
        save()
        AssistantHost.shared.grantsChanged()
    }

    /// Gone here; the host tells the server, whose tokens for it stop.
    func remove(_ id: String) {
        for request in requests where request.assistant == id { SyncCenter.shared.closeAssistantApproval(request.id) }
        requests.removeAll { $0.assistant == id }
        grants.removeAll { $0.id == id }
        save()
        AssistantRunner.shared.stop(id)
        AssistantHost.shared.disconnect(id)
        // Its tasks go with it: left running they'd have no grant to hold them.
        for session in Agents.shared.sessions where session.assistantID == id && session.state.live {
            _ = Agents.shared.stop(session.id)
        }
    }

    func ask(_ request: AssistantRequest) {
        for old in requests where old.assistant == request.assistant && old.what == request.what && old.site == request.site {
            SyncCenter.shared.closeAssistantApproval(old.id)
        }
        requests.removeAll { $0.assistant == request.assistant && $0.what == request.what && $0.site == request.site }
        requests.append(request)
        SyncCenter.shared.publishAssistantAccess(request)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60 + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.requests.contains(request) else { return }
                self.requests.removeAll { $0 == request }
                SyncCenter.shared.closeAssistantApproval(request.id)
            }
        }
    }

    /// The user's answer to a request: a yes switches it on.
    func answer(_ request: AssistantRequest, yes: Bool) {
        guard requests.contains(request) else { return }
        requests.removeAll { $0 == request }
        SyncCenter.shared.closeAssistantApproval(request.id)
        guard yes else { return }
        update(request.assistant) { grant in
            switch request.what {
            case "mail": grant.mail = true
            case "messages": grant.messages = true
            case "cards": grant.cards = true
            case "site":
                if let site = request.site {
                    if !grant.allowedSites.orEmpty.contains(site) { grant.allowedSites = grant.allowedSites.orEmpty + [site] }
                    if !grant.only.isEmpty, !grant.only.contains(site) { grant.only.append(site) }
                }
            default: break
            }
        }
    }

    func used(_ id: String) {
        guard let at = grants.firstIndex(where: { $0.id == id }) else { return }
        // Said to the minute: a write per call would be a write per click.
        if let last = grants[at].used, Date().timeIntervalSince(last) < 60 { return }
        grants[at].used = Date()
        save()
    }

    private func save() {
        store.set(try? JSONEncoder().encode(grants), forKey: "assistants.grants")
    }

    /// What the consent sheet offers to keep an assistant away from, on by
    /// default: banks, payments, money apps and government sites. A rule
    /// is a site or a suffix (`gov` is every .gov site).
    static let guarded = [
        "gov", "gov.uk", "gc.ca", "gov.au", "gouv.fr", "bund.de", "gosuslugi.ru", "nalog.gov.ru", "irs.gov", "ssa.gov",
        "bank", "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "capitalone.com", "usbank.com",
        "americanexpress.com", "schwab.com", "fidelity.com", "vanguard.com", "robinhood.com", "paypal.com", "venmo.com",
        "wise.com", "revolut.com", "monzo.com", "n26.com", "coinbase.com", "binance.com", "kraken.com",
        "sberbank.ru", "tbank.ru", "tinkoff.ru", "alfabank.ru", "vtb.ru",
    ]

    /// A new id for an assistant: 22 characters of base64url.
    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }

    /// The name an assistant is shown under, from what its client said.
    static func name(client: String) -> String {
        let lower = client.lowercased()
        if lower.contains("chatgpt") || lower.contains("openai") { return "ChatGPT" }
        if lower == "dots" { return "dots" }
        if lower.contains("claude") { return "Claude" }
        if lower == "grok-bot" { return "Grok Bot" }
        if lower.contains("grok") { return "Grok" }
        if lower.contains("gemini") { return "Gemini" }
        if lower.contains("muse") { return "Muse" }
        if lower.contains("yab-mcp") { return "Agent" }
        let trimmed = client.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Assistant" : String(trimmed.prefix(40))
    }

    /// Whether `url` is a site the assistant may open, and if not, why.
    func refusal(_ grant: AssistantGrant, url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return url == nil ? nil : "status: refused_site\n\(grant.name) can open only web pages (http and https)."
        }
        let site = AgentRules.site(url)
        func matches(_ list: [String]) -> Bool {
            list.contains { rule in
                let rule = rule.lowercased().trimmingCharacters(in: .whitespaces)
                return !rule.isEmpty && (site == rule || (url.host()?.lowercased() ?? "").hasSuffix("." + rule) || url.host()?.lowercased() == rule)
            }
        }
        if matches(grant.never), !grant.allowedSites.orEmpty.contains(site) {
            return "status: refused_site\nThe user doesn't let \(grant.name) open \(site) (Yab › Settings › AI › Assistants › \(grant.name)). Don't try another way; tell the user."
        }
        if !grant.only.isEmpty, !matches(grant.only) {
            return "status: refused_site\nThe user lets \(grant.name) open only \(grant.only.joined(separator: ", ")). \(site) isn't one of them; tell the user."
        }
        return nil
    }

    /// Why a tab of an assistant's may not go to `url` however it got
    /// there: a link, a redirect, a script. Nil for everyone else's tabs.
    func refusal(tab agent: String?, url: URL) -> String? {
        guard let id = Agents.shared.session(agent)?.assistantID else { return nil }
        guard let grant = grant(id) else { return "removed" }
        return refusal(grant, url: url)
    }
}

private extension Optional where Wrapped == [String] {
    var orEmpty: [String] { self ?? [] }
}

extension Agents.Session {
    /// The assistant a session works for, itself or through the task or
    /// subagent that made it.
    @MainActor var assistantID: String? {
        var at: Agents.Session? = self
        var seen: Set<String> = []
        while let now = at, seen.insert(now.id).inserted {
            if let id = now.assistant { return id }
            at = Agents.shared.session(now.parent)
        }
        return nil
    }
}

extension Agents {
    func assistant(of session: String?) -> AssistantGrant? {
        Assistants.shared.grant(self.session(session)?.assistantID)
    }
}

/// Every call made for an assistant meets this on the bench, past what its
/// `yab mcp` lists: the user's tabs and its own (never another agent's or a
/// private one), its space, its sites, nothing of the user's Mac. The origin
/// never widens anything: it only narrows.
@MainActor
enum AssistantBoundary {
    /// The words an assistant's calls may use, whatever its server asks:
    /// its own tabs, its tasks, and what the user switched on for it.
    static let allowed: Set<String> = [
        "open", "nav", "act", "press", "snapshot", "settle", "text", "wait", "close", "shot",
        "agent-go", "agent-tabs", "agent-dialog", "agent-download", "agent-downloads", "agent-pdf",
        "handoff", "handoff-wait", "agent-sign-in", "agent-file", "agent-name", "agent-caps", "agent-detach",
        "agent-run", "agent-wait", "agent-stop", "agent-steer", "agent-queue", "app-status",
        "agent-assistant", "agent-approval", "agent-approval-wait", "agent-access-request",
    ]
    static let mailVerbs: Set<String> = ["agent-mail-search", "agent-mail-read", "agent-mail-draft", "agent-mail-send", "agent-mail-code"]
    static let messagesVerbs: Set<String> = ["agent-sms"]
    static let cardsVerbs: Set<String> = ["agent-autofill"]
    /// Words that open or go to an address.
    static let going: Set<String> = ["open", "nav", "agent-go"]
    /// At most this many tabs of one assistant open at once, and tasks running.
    static let tabLimit = 12
    static let taskLimit = 3

    enum Verdict {
        case pass([String: Any])
        case refuse(String)
    }

    /// The session a call speaks for, and its assistant.
    static func caller(_ request: [String: Any], agents: Agents? = nil) -> (session: String, grant: AssistantGrant)? {
        let agents = agents ?? .shared
        for key in ["callerSession", "session"] {
            if let id = request[key] as? String, let grant = agents.assistant(of: id) { return (id, grant) }
        }
        return nil
    }

    /// Use the save handler's effective targets before any read or export.
    /// Values and policy are supplied so selection never registers an assistant.
    nonisolated static func targetRefusal<T>(_ request: [String: Any], find: ([String: Any]) -> T?, refusal: (T) -> String?) -> String? {
        let ids = request["do"] as? String == "agent-pdf"
            ? (request["tabs"] as? [String] ?? []).filter { !$0.isEmpty } : []
        let targets = ids.isEmpty ? [find(request)].compactMap { $0 }
            : ids.compactMap { find(["id": $0]) }
        for target in targets {
            if let why = refusal(target) { return why }
        }
        return nil
    }

    /// The call as it may go, or why it may not.
    static func check(_ request: [String: Any], bench: Bench, browser: Browser, agents: Agents? = nil) -> Verdict {
        let agents = agents ?? .shared
        guard let found = caller(request, agents: agents) else {
            // A session of an assistant that was removed has no grant left
            // to hold it: it does nothing, rather than all the user may.
            for key in ["callerSession", "session"] {
                if let id = request[key] as? String, agents.session(id)?.assistantID != nil {
                    return .refuse("status: removed\nThe user removed this assistant from Yab. Nothing was done.")
                }
            }
            return .pass(request)
        }
        let session = found.session, grant = found.grant
        let verb = request["do"] as? String ?? ""
        if grant.paused {
            return .refuse("status: paused\nThe user paused \(grant.name) in Yab. Nothing was done; ask them to resume it in Yab › Settings › AI › Assistants.")
        }
        if verb == "spaces", grant.allSpaces == true {
            Assistants.shared.used(grant.id)
            return .pass(request)
        }
        if !allowed.contains(verb) {
            if mailVerbs.contains(verb) {
                if !grant.mail { return .refuse("status: refused_tool\nThe user hasn't let \(grant.name) use their mail. They can switch it on in Yab › Settings › AI › Assistants › \(grant.name).") }
            } else if messagesVerbs.contains(verb) {
                if !grant.messages { return .refuse("status: refused_tool\nThe user hasn't let \(grant.name) read codes from Messages.") }
            } else if cardsVerbs.contains(verb) {
                if !grant.cards { return .refuse("status: refused_tool\nThe user hasn't let \(grant.name) fill their saved cards and addresses.") }
            } else {
                return .refuse("status: refused_tool\n\(grant.name) can't use \(verb) in Yab.")
            }
        }
        // Another session's tab, or all of them: not there, to an assistant.
        if request["id"] as? String == "all" { return .refuse("status: refused_tool\n\(grant.name) works only in tabs it opened itself.") }
        if let refusal = targetRefusal(request, find: { bench.find($0, in: browser) }, refusal: { tab in
            if !grant.permits(tab, in: browser) {
                return "status: refused_space\nThe user lets \(grant.name) work only in \(grant.spaceName(in: browser.spaces)). They can choose All spaces in Yab › Settings › AI › Assistants › \(grant.name). Nothing was done."
            }
            if agents.session(tab.agent)?.assistantID != grant.id {
                // The user's own tabs follow the same rules for every
                // member of an export; private and other agents' tabs don't.
                guard !tab.bench, !tab.shy else {
                    return "No tab \(Bench.short(tab)): \(grant.name) can use the user's tabs and the ones it opened (open)."
                }
                if let refusal = Assistants.shared.refusal(grant, url: tab.address ?? tab.pending) { return refusal }
            }
            return nil
        }) { return .refuse(refusal) }
        // A task's own session: only one this assistant started.
        if ["agent-wait", "agent-stop", "agent-steer", "agent-queue"].contains(verb),
           let task = request["session"] as? String, task != session, agents.session(task)?.assistantID != grant.id {
            return .refuse("No task \(task) of \(grant.name)'s.")
        }
        if verb == "open" {
            let mine = browser.everyTab.filter { agents.session($0.agent)?.assistantID == grant.id }.count
            if mine >= tabLimit {
                return .refuse("status: too_many\n\(grant.name) has \(mine) tabs open in Yab, the most it may. Close the ones you are done with (close), then open this one.")
            }
        }
        if verb == "agent-run", request["resume"] == nil {
            let running = agents.sessions.filter { $0.assistant == grant.id && $0.cli != "external" && $0.state.live }.count
            if running >= taskLimit {
                return .refuse("status: too_many\n\(grant.name) has \(running) tasks running in Yab, the most at once. Wait for one with task_status, or stop one (task_stop).")
            }
        }
        var out = request
        if going.contains(verb) {
            // `nav` names its address as `how`, beside back and forward.
            let raw = request["url"] as? String ?? (request["how"] as? String).flatMap { ["back", "forward", "reload"].contains($0) ? nil : $0 }
            if let raw, let refusal = Assistants.shared.refusal(grant, url: Address.url(from: raw)) {
                return .refuse(refusal)
            }
            // All spaces keeps the requested sign-ins (or normal site
            // selection); older grants still force their original home.
            if grant.allSpaces != true {
                if let space = grant.space, let found = browser.spaces.first(where: { $0.id == space }) {
                    out["space"] = found.name
                } else {
                    out["space"] = browser.spaces.first?.name
                }
            }
        }
        if verb == "agent-run" {
            if let resume = request["resume"] as? String, agents.session(resume)?.assistantID != grant.id {
                return .refuse("No task \(resume) of \(grant.name)'s to carry on.")
            }
            out["access"] = "browser"
            out["assistant"] = grant.id
            out["folder"] = nil
            out["person"] = nil
        }
        Assistants.shared.used(grant.id)
        return .pass(out)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while plain.count % 4 != 0 { plain += "=" }
        self.init(base64Encoded: plain)
    }
}

extension Preferences {
    /// How much an agent asks first: the user's mode, or for an assistant
    /// in the cloud the one picked for it.
    func asking(_ session: String?) -> AgentAsking {
        guard let assistant = Agents.shared.assistant(of: session) else {
            // Removed while its task ran: asks for everything.
            return Agents.shared.session(session)?.assistantID != nil ? .ask : agentsAsking
        }
        // A cloud assistant never skips consequential approvals. A grant
        // saved by an older build with Bypass is treated as Auto here too.
        return assistant.mode == .bypass ? .auto : assistant.mode
    }
}
