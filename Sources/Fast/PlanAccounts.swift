import YabStore
import AppKit
import CryptoKit
import LocalAuthentication
import Security

// More than one plan behind an agent: a second Claude account, a third
// ChatGPT one. Each extra account is the CLI's own config folder in yab's
// (CLAUDE_CONFIG_DIR, CODEX_HOME), signed in there with the CLI's own login,
// so its sign-in lives where the CLI keeps it and never passes through yab.
// The first account is the CLI's usual one, ~/.claude or ~/.codex.
//
// A task starts on the first account in your order that has room left, and
// one that runs out mid-task carries on, same conversation, on the next:
// each extra folder links the usual one's conversations (projects/,
// sessions/), so `--resume` finds the thread whichever account resumes it.
//
// How much room is left is only what the agents themselves say: Claude
// Code's stream carries a rate_limit_event on every run, and Codex's server
// says its limits as they change. Before a task, when yab hasn't heard for
// a few minutes, it asks the CLI, which reads its plan's usage without
// running the model: Claude Code's get_usage, Codex's
// account/rateLimits/read. A new chat whose agent has no room anywhere
// starts on the other agent, if you connected it and it has some, and says
// so; a chat under way never changes agent (Agents.choose).
//
// An API key of yours is an account too (`tail` set), added from Models ›
// Add Account: tried after the plans by default, turned away for a minute
// when its provider says it is rate limited or out of credit. Claude's runs
// in the usual folder with the key as ANTHROPIC_API_KEY; Codex's has a
// folder of its own, signed in there with `codex login --with-api-key`.

struct PlanAccount: Codable, Identifiable, Equatable {
    /// The CLI's name for its usual account, else "claude.3fa9c1".
    let id: String
    /// "claude" or "codex".
    let cli: String
    /// Its own config folder; nil while it uses the CLI's usual one.
    var home: String?
    var email: String?
    /// The plan as the CLI names it: "max", "pro", "plus".
    var plan: String?
    /// An API key's last four letters: this account is that key, kept in
    /// the keychain under its id (AgentKey.secret).
    var tail: String?

    var usual: Bool { id == cli }
    var keyed: Bool { tail != nil }
}

/// What an account's plan last said about its limits.
struct PlanQuota: Codable, Equatable {
    /// Out of room until then.
    var out: Date?
    /// The fullest window, 0 to 1, and when it starts over.
    var used: Double?
    var resets: Date?
    /// "five_hour" or "seven_day", Claude's names; Codex's are made to match,
    /// and its month (a Free or Go plan's) is "thirty_day".
    var window: String?
    var seen = Date()
    /// Every window the plan counts, by the same names: how full each is
    /// and when it starts over, for the ring's popover.
    var windows: [String: PlanWindow]?
}

struct PlanWindow: Codable, Equatable {
    var used: Double
    var resets: Date?
}

/// A plan Codex's server named that the account's sign-in token doesn't
/// say yet: the plan, and what the token said when the server said it.
/// The id token is minted at sign-in and only renewed when Codex refreshes
/// it, every eight days or so, so a Free account upgraded to Plus read as
/// Free until then (feedback #734).
struct HeardPlan: Codable, Equatable {
    var plan: String
    var token: String?
}

@MainActor
final class PlanAccounts: ObservableObject {
    static let shared = PlanAccounts()

    /// The extra accounts, and the order every account is tried in.
    @Published private(set) var extras: [PlanAccount] = []
    @Published private(set) var order: [String] = []
    @Published private(set) var quotas: [String: PlanQuota] = [:]
    /// Plans the server said ahead of the token, by account.
    private(set) var heardPlans: [String: HeardPlan] = [:]
    /// What each usual account is, read from its CLI.
    @Published private(set) var usual: [String: PlanAccount] = [:]
    /// Accounts whose CLI says they are signed out.
    @Published private(set) var signedOut: Set<String> = []
    /// The CLI an account is being added to, while its sign-in is open.
    @Published private(set) var adding: String?
    /// Where the add is, for its row's words.
    @Published private(set) var step: Step?
    /// Why the last add stopped, in the row until the next press.
    @Published private(set) var trouble: String?
    enum Step: Equatable {
        case opening
        /// The page in a private Yab tab.
        case yab
        /// The page in another browser, by its name (Codex opens its own).
        case browser(String?)
        /// The CLI is done; asking it who signed in.
        case checking

        init(_ page: Agents.SignInPage) {
            switch page {
            case .opening: self = .opening
            case .yab: self = .yab
            case .browser(let name): self = .browser(name)
            }
        }
    }

    /// The Add Account row's words at each step.
    static func stepWords(_ cli: String, _ step: Step?) -> String {
        let plan = AgentSetupModel.plan(cli)
        switch step {
        case .opening, nil: return "Opening the sign-in…"
        case .yab: return "Sign in to your other \(plan) account in the private tab"
        case .browser(let name): return "Sign in to your other \(plan) account in \(name ?? "your browser"). Sign out of the usual one there first."
        case .checking: return "Checking the account…"
        }
    }

    static let notAdded = "The account wasn't added."
    static func already(_ email: String) -> String { "\(email) is already here." }

    private let consent: ProviderConsent?
    private let settings: UserDefaults

    init(settings: UserDefaults = Store.settings, consent: ProviderConsent? = nil) {
        self.consent = consent
        self.settings = settings
        if let data = settings.data(forKey: "plans.accounts"),
           let saved = try? JSONDecoder().decode([PlanAccount].self, from: data) { extras = saved }
        order = settings.stringArray(forKey: "plans.order") ?? []
        if let data = settings.data(forKey: "plans.quotas"),
           let saved = try? JSONDecoder().decode([String: PlanQuota].self, from: data) { quotas = saved }
        if let data = settings.data(forKey: "plans.usual"),
           let saved = try? JSONDecoder().decode([String: PlanAccount].self, from: data) { usual = saved }
        signedOut = Set(settings.stringArray(forKey: "plans.signedOut") ?? [])
        if let data = settings.data(forKey: "plans.heard"),
           let saved = try? JSONDecoder().decode([String: HeardPlan].self, from: data) { heardPlans = saved }
        for cli in AgentSetupModel.clis where cli != "gemini" && usual[cli] == nil { usual[cli] = PlanAccount(id: cli, cli: cli) }
    }

    private func save() {
        settings.set(try? JSONEncoder().encode(extras), forKey: "plans.accounts")
        settings.set(order, forKey: "plans.order")
        settings.set(try? JSONEncoder().encode(usual), forKey: "plans.usual")
        settings.set(Array(signedOut).sorted(), forKey: "plans.signedOut")
    }

    private func saveQuotas() {
        settings.set(try? JSONEncoder().encode(quotas), forKey: "plans.quotas")
    }

    private func saveHeard() {
        settings.set(try? JSONEncoder().encode(heardPlans), forKey: "plans.heard")
    }

    // MARK: - which one

    /// Every account of an agent, in the order they are tried.
    func all(_ cli: String) -> [PlanAccount] {
        let every = [usual[cli] ?? PlanAccount(id: cli, cli: cli)] + extras.filter { $0.cli == cli }
        return every.sorted { rank($0.id) < rank($1.id) }
    }

    private func rank(_ id: String) -> Int { order.firstIndex(of: id) ?? (order.count + (id.contains(".") ? 1 : 0)) }

    func account(_ id: String?) -> PlanAccount? {
        guard let id else { return nil }
        return usual[id] ?? extras.first { $0.id == id }
    }

    /// Out of room right now.
    func out(_ id: String, now: Date = Date()) -> Bool {
        guard let until = quotas[id]?.out else { return false }
        return until > now
    }

    /// No room for a new task: turned away, or a window used up. A plan
    /// with extra usage still takes one then, but it costs money, and
    /// another plan's room doesn't.
    func full(_ id: String, now: Date = Date()) -> Bool {
        (fullest(id, now: now) ?? 0) >= 1
    }

    /// The account a task on this agent starts on: the first with room
    /// that is signed in, else one used up but not turned away (extra
    /// usage), else whichever comes back soonest. `skipping` leaves out
    /// those already tried for this task.
    func pick(_ cli: String, skipping: Set<String> = []) -> PlanAccount? {
        let every = all(cli).filter { !skipping.contains($0.id) }
        // The usual one is always there to try, even signed out: the task
        // then asks you to sign in, as it did before there were others.
        let ready = every.filter { !full($0.id) && ($0.usual || !signedOut.contains($0.id)) }
        if let first = ready.first(where: { !signedOut.contains($0.id) }) ?? ready.first { return first }
        guard skipping.isEmpty else { return nil }
        return every.min { back($0.id) < back($1.id) }
    }

    /// When an account takes a task again: now, unless it was turned away.
    private func back(_ id: String) -> Date {
        out(id) ? quotas[id]?.out ?? .distantFuture : .distantPast
    }

    /// When this agent has room again: the soonest any of its signed-in
    /// accounts is back, from being turned away or from a full window
    /// starting over. Nil when none says, or one has room now.
    func roomAgain(_ cli: String, now: Date = Date()) -> Date? {
        var soonest: Date?
        for account in all(cli) where !signedOut.contains(account.id) {
            guard full(account.id, now: now) else { return nil }
            let back = out(account.id, now: now) ? quotas[account.id]?.out
                : windows(account.id, now: now).filter { $0.window.used >= 1 }.compactMap(\.window.resets).max()
            if let back { soonest = min(soonest ?? back, back) }
        }
        return soonest
    }

    /// Every account of this agent is signed out.
    func allSignedOut(_ cli: String) -> Bool {
        all(cli).allSatisfy { signedOut.contains($0.id) }
    }

    /// Whether any account of this agent has room, leaving out those
    /// already tried for a task.
    func hasRoom(_ cli: String, skipping: Set<String> = []) -> Bool {
        all(cli).contains { !skipping.contains($0.id) && !full($0.id) && !signedOut.contains($0.id) }
    }

    /// The env a CLI runs in for this account: its own folder, if it has one.
    /// Your `claude setup-token` token and the API key you connected with
    /// (AgentKey) are the usual account's: Claude Code takes either before
    /// any folder's sign-in, so another account never gets them.
    func env(_ account: PlanAccount?, base: [String: String]) -> [String: String] {
        guard let account else { return base }
        var env = Self.environment(account, base: base, secret: AgentKey.secret)
        if account.cli == "claude", account.usual, let given = env[AgentKey.anthropic],
           extras.contains(where: { $0.keyed && AgentKey.secret($0.id) == given }) {
            // Back to the usual account from a key's: its own key, if any.
            env[AgentKey.anthropic] = AgentKey.claude()
        }
        return env
    }

    /// The one rule for an account's environment, for the task that runs
    /// on it (env) and for a look at whether it is signed in (read): its
    /// own folder, and your token and key for the usual account only.
    /// `secret` gives a keyed account's key; nil while only looking, which
    /// never loads one.
    static func environment(_ account: PlanAccount, base: [String: String],
                            secret: ((String) -> String?)?) -> [String: String] {
        if account.cli == "cursor" { return CursorRunner.environment(base) }
        var env = base
        if account.cli == "claude", !account.usual {
            env[Shell.claudeToken] = nil
            env[AgentKey.anthropic] = account.keyed ? secret?(account.id) : nil
        }
        guard let home = account.home else { return env }
        env[account.cli == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = home
        return env
    }

    /// A look's read of whether this account is signed in, kept as the
    /// launcher's pick reads it: a task then starts on the account the look
    /// found signed in. Dropped when the account changed since the read.
    func heard(_ account: PlanAccount, signedIn: Bool, revision: Int) {
        guard self.account(account.id) == account, identityRevision(account.id) == revision,
              signedOut.contains(account.id) == signedIn else { return }
        if signedIn { signedOut.remove(account.id) } else { signedOut.insert(account.id) }
        save()
    }

    func moveFirst(_ id: String, _ cli: String) {
        var ids = all(cli).map(\.id)
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        order = order.filter { !ids.contains($0) } + ids
        save()
    }

    // MARK: - what the plans say

    /// Claude Code's rate_limit_event: every window's use, and whether
    /// this request was turned away.
    func heard(claude info: [String: Any], on id: String?) {
        guard let id else { return }
        var quota = PlanQuota()
        let windows = info["unifiedWindows"] as? [String: [String: Any]] ?? [:]
        quota.windows = windows.compactMapValues { window in
            (window["utilization"] as? Double).map { PlanWindow(used: $0, resets: (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }) }
        }
        if let fullest = windows.max(by: { ($0.value["utilization"] as? Double ?? 0) < ($1.value["utilization"] as? Double ?? 0) }) {
            quota.used = fullest.value["utilization"] as? Double
            quota.resets = (fullest.value["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            quota.window = fullest.key
        }
        if info["status"] as? String == "rejected" {
            let resets = (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            quota.out = resets ?? Date().addingTimeInterval(3600)
            if let type = info["rateLimitType"] as? String {
                quota.window = type
                quota.resets = resets
                quota.used = 1
                quota.windows?[type] = PlanWindow(used: 1, resets: resets)
            }
        }
        quotas[id] = quota
        saveQuotas()
    }

    /// How long a key turned away (rate limited, out of credit) sits out.
    nonisolated static let keyWait: TimeInterval = 60

    /// Turned away for its limits, with or without saying until when.
    func ranOut(_ id: String?, until: Date? = nil) {
        guard let id else { return }
        var quota = quotas[id] ?? PlanQuota()
        // A key has no window to wait out: its provider is asked again soon.
        let wait: TimeInterval = account(id)?.keyed == true ? Self.keyWait : 3600
        quota.out = until ?? quota.resets.flatMap { $0 > Date() ? $0 : nil } ?? Date().addingTimeInterval(wait)
        quota.used = 1
        quota.seen = Date()
        quotas[id] = quota
        saveQuotas()
    }

    /// Codex's limits as its conversation's file last had them. It keeps
    /// them there after each turn, not in `exec --json`.
    func readCodex(thread: String?, on id: String?) {
        guard let thread, let id else { return }
        let source = account(id)?.home.map { URL(fileURLWithPath: $0) } ?? AgentSetup.home.appendingPathComponent(".codex")
        let base = Store.testing ? CodexProbe.home(root: Store.file("codex"), source: source) : source
        let sessions = base.appendingPathComponent("sessions")
        let days = [Date(), Date().addingTimeInterval(-86_400)].map { day -> URL in
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
            return sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
        }
        let file = days.lazy.compactMap { day in
            (try? FileManager.default.contentsOfDirectory(atPath: day.path))?
                .first { $0.hasSuffix(thread + ".jsonl") }
                .map { day.appendingPathComponent($0) }
        }.first
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.contains("\"rate_limits\"") }),
              let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let limits = (event["payload"] as? [String: Any])?["rate_limits"] as? [String: Any]
        else { return }
        heard(codex: limits, on: id)
    }

    /// Codex's limits, as its server says them the moment they change
    /// (`account/rateLimits/updated`, camelCase) or as its file keeps them
    /// (snake_case).
    func heard(codex limits: [String: Any], on id: String?) {
        guard let id else { return }
        func number(_ window: [String: Any], _ camel: String, _ snake: String) -> Double? {
            (window[camel] as? NSNumber ?? window[snake] as? NSNumber)?.doubleValue
        }
        var quota = PlanQuota()
        var windows: [String: PlanWindow] = [:]
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any], let percent = number(window, "usedPercent", "used_percent") else { continue }
            let minutes = number(window, "windowDurationMins", "window_minutes") ?? 0
            let name = minutes > 10_080 ? "thirty_day" : minutes >= 1440 ? "seven_day" : "five_hour"
            let resets = number(window, "resetsAt", "resets_at").map { Date(timeIntervalSince1970: $0) }
            windows[name] = PlanWindow(used: percent / 100, resets: resets)
            guard percent / 100 >= quota.used ?? -1 else { continue }
            quota.used = percent / 100
            quota.resets = resets
            quota.window = name
        }
        quota.windows = windows
        heard(codexPlan: limits["planType"] ?? limits["plan_type"], on: id)
        guard quota.used != nil else { return }
        let reached = limits["rateLimitReachedType"] ?? limits["rate_limit_reached_type"]
        if (reached != nil && !(reached is NSNull)) || (quota.used ?? 0) >= 1 {
            quota.out = quota.resets ?? Date().addingTimeInterval(3600)
        }
        quotas[id] = quota
        saveQuotas()
    }

    /// Antigravity has one shared login; its Gemini bucket drives the same
    /// usage ring as the other plans, without inventing extra accounts.
    func heard(gemini quota: PlanQuota) {
        quotas["gemini"] = quota
        saveQuotas()
    }

    // MARK: - asking before a task

    /// What an account said this long ago still stands: yab asks again
    /// only after that.
    nonisolated static let fresh: TimeInterval = 5 * 60

    /// When each account was last asked, so one whose CLI didn't say isn't
    /// asked again before every task.
    private var asked: [String: Date] = [:]

    /// A picker and a starting task can ask for the same account together.
    private var asking: [String: Task<Void, Never>] = [:]

    /// Asks every account of this agent not heard from lately how much room
    /// it has, all at once, and waits for their answers: a second or two,
    /// before the first task after a while, and nothing spent. Blocked
    /// accounts are asked too: a reset in the CLI can restore their room
    /// before the old deadline. Opening the picker checks those immediately.
    func ask(_ cli: String, found: Shell.Found, refreshBlocked: Bool = false) async {
        guard let permit = (consent ?? ProviderConsent.shared).permit(cli), let binary = AgentSetupModel.binary(cli, in: found) else { return }
        if cli == "cursor" {
            // Cursor has no quota endpoint. Refresh its actual login when
            // the model picker opens rather than guessing from keychain names.
            let account = account("cursor") ?? PlanAccount(id: "cursor", cli: "cursor")
            await remember(account, binary: binary, base: found.env, permit: permit)
            return
        }
        let now = Date()
        let due = all(cli).filter { account in
            !account.keyed && !signedOut.contains(account.id)
                && (asking[account.id] != nil || (refreshBlocked && full(account.id, now: now))
                    || ((quotas[account.id].map { now.timeIntervalSince($0.seen) >= Self.fresh } ?? true)
                        && (asked[account.id].map { now.timeIntervalSince($0) >= Self.fresh } ?? true)))
        }
        guard !due.isEmpty else { return }
        let folder = Store.file("agent/plans")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var pending: [Task<Void, Never>] = []
        for account in due {
            if let task = asking[account.id] {
                pending.append(task)
                continue
            }
            asked[account.id] = now
            let env = env(account, base: found.env)
            let task = Task {
                guard permit.valid else { asking[account.id] = nil; return }
                if let said = await Self.usage(cli, binary: binary, env: env, in: folder, permit: permit), permit.valid {
                    if cli == "codex" { heard(codexAsked: said, on: account.id) } else { heard(claudeUsage: said, on: account.id) }
                }
                if cli == "codex", permit.valid { await renew(account.id, binary: binary, env: env, in: folder, permit: permit) }
                asking[account.id] = nil
            }
            asking[account.id] = task
            pending.append(task)
        }
        for task in pending { await task.value }
    }

    /// When each account's token was last renewed for a plan the server
    /// said ahead of it.
    private var renewed: [String: Date] = [:]
    /// Renewed at most this often for one account: a renewal that didn't
    /// change the token isn't tried again before every task.
    nonisolated static let renewEvery: TimeInterval = 3600

    /// The server named a plan the token doesn't: Codex renews its own
    /// sign-in (account/read with refreshToken, its usual refresh, written
    /// by Codex to its own auth.json), so its id token, the models its
    /// server lists, and every copy of Codex agree with the plan.
    private func renew(_ id: String, binary: String, env: [String: String], in folder: URL, permit: ProviderLaunchPermit) async {
        guard heardPlans[id] != nil, renewed[id].map({ Date().timeIntervalSince($0) >= Self.renewEvery }) ?? true else { return }
        renewed[id] = Date()
        guard await Self.renewCodex(binary: binary, env: env, in: folder, permit: permit), permit.valid,
              var account = account(id) else { return }
        let plan = settled(id, token: Self.codexAuth(home: account.home).plan) ?? account.plan
        CodexCatalog.forget(home: account.home)
        guard plan != account.plan else { return }
        account.plan = plan
        put(account, semanticChange: false)
        save()
    }

    /// Codex's app-server renews its ChatGPT sign-in: whether it answered.
    nonisolated static func renewCodex(binary: String, env: [String: String], in folder: URL, permit: ProviderLaunchPermit) async -> Bool {
        guard permit.valid else { return false }
        let said = await Shell.talk(binary, ["app-server"], env: env, in: folder, saying: [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "yab", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "account/read", "params": ["refreshToken": true]],
        ], limit: 15, permit: permit) { ($0["id"] as? NSNumber)?.intValue == 2 }
        return said?["result"] is [String: Any]
    }

    /// The same for several agents at once, for a page that shows them all.
    func ask(_ clis: [String], found: Shell.Found, refreshBlocked: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for cli in clis { group.addTask { await self.ask(cli, found: found, refreshBlocked: refreshBlocked) } }
        }
    }

    /// The plan's usage as the CLI reads it, or nil if it didn't say within
    /// a few seconds. Claude Code: a get_usage control request on its
    /// stream, no hooks, servers or tools of anyone's (--safe-mode), and no
    /// message, so no model runs. Codex: its server's
    /// account/rateLimits/read, with no thread opened.
    nonisolated static func usage(_ cli: String, binary: String, env: [String: String], in folder: URL, permit: ProviderLaunchPermit? = nil) async -> [String: Any]? {
        guard let permit, permit.valid else { return nil }
        if cli == "codex" {
            let said = await Shell.talk(binary, ["app-server"], env: env, in: folder, saying: [
                ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "yab", "version": "1"]]],
                ["jsonrpc": "2.0", "method": "initialized"],
                ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"],
            ], permit: permit) { ($0["id"] as? NSNumber)?.intValue == 2 }
            return said?["result"] as? [String: Any]
        }
        let said = await Shell.talk(binary, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                             "--safe-mode", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--tools", ""],
                                    env: env, in: folder, saying: [
                                        ["type": "control_request", "request_id": "yab-usage",
                                         "request": ["subtype": "get_usage", "skip_behaviors": true]],
                                    ], permit: permit) { $0["type"] as? String == "control_response" }
        let response = said?["response"] as? [String: Any]
        guard response?["subtype"] as? String == "success" else { return nil }
        return response?["response"] as? [String: Any]
    }

    /// Claude Code's get_usage: each window's use, 0 to 100, and when it
    /// starts over. Nothing when it couldn't read the plan's usage, which
    /// it can't for every plan, or at every moment.
    func heard(claudeUsage usage: [String: Any], on id: String) {
        guard let limits = usage["rate_limits"] as? [String: Any] else { return }
        var windows: [String: PlanWindow] = [:]
        for name in ["five_hour", "seven_day"] {
            guard let window = limits[name] as? [String: Any], let percent = (window["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows[name] = PlanWindow(used: percent / 100, resets: Self.date(window["resets_at"]))
        }
        guard let fullest = windows.max(by: { $0.value.used < $1.value.used }) else { return }
        var quota = PlanQuota()
        quota.windows = windows
        quota.used = fullest.value.used
        quota.resets = fullest.value.resets
        quota.window = fullest.key
        if fullest.value.used >= 1 { quota.out = fullest.value.resets ?? Date().addingTimeInterval(3600) }
        quotas[id] = quota
        saveQuotas()
    }

    /// A plan's id as Codex's server names it, or nil for none or "unknown".
    nonisolated static func planName(_ raw: Any?) -> String? {
        guard let raw = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty, raw != "unknown" else { return nil }
        return raw
    }

    /// The plan Codex's server says the account is on, with its limits:
    /// read from the account's subscription as it is now, so it beats the
    /// token's claim until the token is renewed (settled). A new plan
    /// serves other models, so the model list is asked again.
    func heard(codexPlan raw: Any?, on id: String) {
        guard let plan = Self.planName(raw), var account = account(id), account.cli == "codex", !account.keyed else { return }
        let token = Self.codexAuth(home: account.home).plan
        let ahead = plan == token ? nil : HeardPlan(plan: plan, token: token)
        if heardPlans[id] != ahead {
            heardPlans[id] = ahead
            saveHeard()
        }
        guard account.plan != plan else { return }
        account.plan = plan
        put(account, semanticChange: false)
        save()
        CodexCatalog.forget(home: account.home)
    }

    /// The plan to show for what the token says now: the server's while
    /// the token still says what it did then, the token's once it changed.
    private func settled(_ id: String, token: String?) -> String? {
        guard let heard = heardPlans[id] else { return token }
        guard let token, token != heard.token else { return heard.plan }
        heardPlans[id] = nil
        saveHeard()
        return token
    }

    /// Codex's account/rateLimits/read: its windows, as its server says
    /// them as they change, and whether the plan itself still takes work
    /// (past that, only bought credits would).
    func heard(codexAsked answer: [String: Any], on id: String) {
        guard let limits = answer["rateLimits"] as? [String: Any] else { return }
        heard(codex: limits, on: id)
        if answer["ordinaryUsageAllowed"] as? Bool == false, !out(id) { ranOut(id) }
    }

    /// A time as the CLIs write it: ISO 8601, or seconds since 1970.
    nonisolated static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        guard let text = value as? String else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text)
    }

    /// Words that mean a plan turned a request away for its limits.
    nonisolated static func limitWords(_ said: String) -> Bool {
        let lower = said.lowercased()
        return ["usage limit", "usage_limit", "rate limit", "rate_limit", "hit your", "weekly limit", "limit reached", "status\":429",
                "credit balance", "insufficient_quota"]
            .contains { lower.contains($0) }
    }

    /// The windows to show, fullest first counted out, each as it is now:
    /// one that has started over since is empty again.
    func windows(_ id: String, now: Date = Date()) -> [(name: String, window: PlanWindow)] {
        guard let quota = quotas[id] else { return [] }
        var all = quota.windows ?? [:]
        if all.isEmpty, let used = quota.used, let name = quota.window { all[name] = PlanWindow(used: used, resets: quota.resets) }
        return ["five_hour", "seven_day", "thirty_day", "gemini-weekly"].compactMap { name in
            guard var window = all[name] else { return nil }
            if let resets = window.resets, resets < now { window = PlanWindow(used: 0, resets: nil) }
            return (name, window)
        }
    }

    /// How full the fullest window is now, 0 to 1, or nil before yab has
    /// heard.
    func fullest(_ id: String, now: Date = Date()) -> Double? {
        if out(id, now: now) { return 1 }
        return windows(id, now: now).map(\.window.used).max()
    }

    /// "Weekly limit, back Fri 10 PM" or "49% of the week used", or nil
    /// before yab has run anything on it.
    func words(_ id: String, now: Date = Date()) -> String? {
        guard let quota = quotas[id] else { return nil }
        let named = Self.named(quota.window)
        if let out = quota.out, out > now {
            return named.limit + ", back " + Self.when(out, now: now)
        }
        guard let used = quota.used else { return nil }
        // A window that has started over since says nothing of now.
        if let resets = quota.resets, resets < now { return nil }
        return "\(Int((used * 100).rounded()))% of " + named.span + " used"
    }

    /// A window's words: its limit, the span it counts, and its title in
    /// the ring's popover and the model picker.
    nonisolated static func named(_ window: String?) -> (limit: String, span: String, title: String) {
        switch window {
        case "seven_day", "gemini-weekly": ("Weekly limit", "the week", "Weekly")
        case "thirty_day": ("Monthly limit", "the month", "Monthly")
        default: ("5-hour limit", "5 hours", "5 hours")
        }
    }

    /// A plan's tier as its maker shows it. Claude Code says "max"; Codex's
    /// token says "prolite" for Pro 100 and, as Codex's own /status reads
    /// it, "team" for Business and "business" for Enterprise.
    nonisolated static func tier(_ cli: String, _ raw: String) -> String {
        let id = raw.lowercased()
        if cli == "codex" {
            switch id {
            case "free": return "Free"
            case "go": return "Go"
            case "plus": return "Plus"
            case "prolite": return "Pro 100"
            case "pro": return "Pro 200"
            case "promax": return "Pro 500"
            case "team", "self_serve_business_prolite", "self_serve_business_usage_based": return "Business"
            case "business", "enterprise", "hc", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based": return "Enterprise"
            case "edu", "education": return "Edu"
            case "edu_plus": return "Edu Plus"
            case "edu_pro": return "Edu Pro"
            default: break
            }
        }
        if cli == "gemini" {
            // The CLI's header says "Antigravity Starter Quota" or "Google
            // AI Pro": the tier, without the product around it.
            let tier = raw.replacingOccurrences(of: #"^Antigravity\s+|\s+Quota$"#, with: "", options: .regularExpression)
            return tier.isEmpty ? raw : tier
        }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// "3:40 PM" today, "Fri 10 PM" within the week, else "Oct 3".
    nonisolated static func when(_ date: Date, now: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US")
        if Calendar.current.isDate(date, inSameDayAs: now) {
            format.dateFormat = "h:mm a"
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            format.dateFormat = Calendar.current.component(.minute, from: date) == 0 ? "EEE h a" : "EEE h:mm a"
        } else {
            format.dateFormat = "MMM d"
        }
        return format.string(from: date)
    }

    // MARK: - who they are

    private var looking = 0
    private var identityChanges: [String: Int] = [:]

    func identityRevision(_ id: String) -> Int { identityChanges[id, default: 0] }

    /// Each account's email and plan, from the agents' own files or
    /// Cursor's last verified CLI status: this passive read runs nothing.
    func look(_ found: Shell.Found,
              keychain: @escaping @Sendable (String) -> Bool = PlanAccounts.inKeychain) async {
        looking += 1
        let mine = looking
        for cli in AgentSetupModel.clis where cli != "gemini" {
            guard AgentSetupModel.binary(cli, in: found) != nil else { continue }
            for account in all(cli) {
                let revision = identityChanges[account.id, default: 0]
                // A key is signed in while it is kept; its plan's email is
                // never its own.
                if account.keyed {
                    let present = await AgentKey.hasSecret(account.id)
                    guard looking == mine else { return }
                    guard self.account(account.id) == account,
                          identityChanges[account.id, default: 0] == revision else { continue }
                    if present { signedOut.remove(account.id) } else { signedOut.insert(account.id) }
                    continue
                }
                let who = await Self.read(account, env: found.env, revision: revision, keychain: keychain)
                guard looking == mine else { return }
                guard self.account(account.id) == account,
                      identityChanges[account.id, default: 0] == revision else { continue }
                if who.signedIn { signedOut.remove(account.id) } else { signedOut.insert(account.id) }
                guard who.signedIn else {
                    // The CLI may retain the identity after its token goes.
                    var remembered = account
                    remembered.email = account.email ?? who.email
                    remembered.plan = account.plan ?? who.plan
                    put(remembered, semanticChange: false)
                    continue
                }
                // Signed in again as someone already here: one row is enough.
                if !account.usual, let email = who.email?.lowercased(),
                   all(cli).contains(where: { $0.id != account.id && rank($0.id) < rank(account.id) && $0.email?.lowercased() == email }) {
                    remove(account.id)
                    continue
                }
                let plan = settled(account.id, token: who.plan)
                if account.usual {
                    var current = account
                    current.email = who.email ?? account.email
                    current.plan = plan ?? account.plan
                    usual[cli] = current
                } else if let at = extras.firstIndex(where: { $0.id == account.id }),
                          extras[at].email != who.email || extras[at].plan != plan {
                    extras[at].email = who.email ?? extras[at].email
                    extras[at].plan = plan ?? extras[at].plan
                    save()
                }
            }
        }
        save()
    }

    /// Whether an agent is signed in, and as whom, from its own files
    /// alone: nothing runs and no secret is read. Codex: an auth.json in
    /// its CODEX_HOME holding tokens or an API key; the email and plan from
    /// its id token's public claims. Claude Code: the account its
    /// .claude.json says it signed in as, its credentials file where it
    /// keeps one, its keychain item (only whether it is there, asked
    /// without a prompt: a login kept nowhere else read as signed out once,
    /// and every task went to ChatGPT, feedback #118), or a key or token
    /// given in the environment.
    static func read(_ cli: String, env: [String: String], revision: Int = 0,
                     keychain: @escaping @Sendable (String) -> Bool = PlanAccounts.inKeychain) async -> (signedIn: Bool, email: String?, plan: String?) {
        if AgentFixture.requested {
            guard cli == "claude", let fixture = AgentFixture.discovery(),
                  let seed = fixture.env["YAB_CONSENT_FIXTURE_IDENTITY"], let data = try? Data(contentsOf: URL(fileURLWithPath: seed)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = object["oauthAccount"] as? [String: String] else { return (false, nil, nil) }
            let named = ["accountUuid", "emailAddress"].contains { !(account[$0] ?? "").isEmpty }
            return (named, account["emailAddress"]?.nilIfEmpty, nil)
        }
        if cli == "cursor" { return CursorRunner.identity(env: env) }
        let given = { (key: String) in !(env[key] ?? "").isEmpty }
        if cli == "codex" { return codexAuth(home: env["CODEX_HOME"]) }
        let folder = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        let config = folder?.appendingPathComponent(".claude.json") ?? AgentSetup.claudeConfig
        let account = (try? Data(contentsOf: config))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["oauthAccount"] as? [String: Any]
        let named = ["accountUuid", "emailAddress"].contains { !((account?[$0] as? String) ?? "").isEmpty }
        let credentials = (folder ?? AgentSetup.home.appendingPathComponent(".claude")).appendingPathComponent(".credentials.json")
        var signedIn = named || FileManager.default.fileExists(atPath: credentials.path)
            || given("ANTHROPIC_API_KEY") || given("CLAUDE_CODE_OAUTH_TOKEN")
        if !signedIn, !AgentFixture.requested { signedIn = await keychainPresence(keychainService(configDir: env["CLAUDE_CONFIG_DIR"]), revision: revision, read: keychain) }
        return (signedIn, (account?["emailAddress"] as? String)?.nilIfEmpty, nil)
    }

    /// Codex's auth.json in this CODEX_HOME (nil: ~/.codex): signed in
    /// when it holds tokens or a key, and the id token's email and plan.
    static func codexAuth(home: String?) -> (signedIn: Bool, email: String?, plan: String?) {
        let home = home.map { URL(fileURLWithPath: $0) } ?? AgentSetup.home.appendingPathComponent(".codex")
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (false, nil, nil) }
        let tokens = auth["tokens"] as? [String: Any] ?? [:]
        let held = ["access_token", "refresh_token", "id_token"].contains { !((tokens[$0] as? String) ?? "").isEmpty }
        let key = !((auth["OPENAI_API_KEY"] as? String) ?? "").isEmpty
        let claims = (tokens["id_token"] as? String).flatMap(Self.claims)
        let plan = (claims?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        return (held || key, claims?["email"] as? String, plan)
    }

    private struct KeychainItem: Hashable {
        let service: String
        let account: String?
        let revision: Int
    }
    private static var keychainReads: [KeychainItem: Task<Bool, Never>] = [:]
    nonisolated private static let keychainQueue = DispatchQueue(label: "dev.serafim.fast.plan-keychain", qos: .utility)

    /// Security can stall even with interaction disabled. Only one blocking
    /// call runs at a time, and repeated reads of its item share the call.
    /// A completed sign-in changes the revision before a fresh refresh.
    /// No timeout guesses that an account is signed out while macOS is busy.
    static func keychainPresence(_ service: String, account: String? = nil, revision: Int = 0,
                                 read: @escaping @Sendable (String) -> Bool) async -> Bool {
        let item = KeychainItem(service: service, account: account, revision: revision)
        if let pending = keychainReads[item] { return await pending.value }
        let pending = Task {
            await withCheckedContinuation { done in
                keychainQueue.async { done.resume(returning: read(service)) }
            }
        }
        keychainReads[item] = pending
        let present = await pending.value
        keychainReads[item] = nil
        return present
    }

    /// Where Claude Code keeps its login in the keychain: "Claude
    /// Code-credentials", and for a CLAUDE_CONFIG_DIR of its own the first
    /// 8 hex of that folder's SHA-256 after it, as Claude Code names it.
    nonisolated static func keychainService(configDir: String?) -> String {
        guard let configDir, !configDir.isEmpty else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    /// Whether a generic password of this service is in the keychain. Its
    /// attributes only, never its secret, with no prompt allowed: a locked
    /// or guarded item still counts as there.
    @Sendable nonisolated static func inKeychain(_ service: String) -> Bool {
        inKeychain(service, account: nil)
    }

    @Sendable nonisolated static func inKeychain(_ service: String, account: String?) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        }
        var found: CFTypeRef?
        let status = Keychain.copyMatching(query as CFDictionary, &found)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// A passive identity check needs config paths and token presence only.
    /// It never loads API-key secrets just to construct a subprocess env.
    static func read(_ account: PlanAccount, env: [String: String], revision: Int = 0,
                     keychain: @escaping @Sendable (String) -> Bool = PlanAccounts.inKeychain) async -> (signedIn: Bool, email: String?, plan: String?) {
        // The environment its task would run in, as the launcher makes it.
        await read(account.cli, env: environment(account, base: env, secret: nil), revision: revision, keychain: keychain)
    }

    /// A JWT's middle part, its public claims.
    private static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var body = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let decoded = Data(base64Encoded: body) else { return nil }
        return try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
    }

    /// Asked of the CLI itself, only on a press of yours (Connect, Add
    /// Account) or as a task starts: Claude Code says who it is in `auth
    /// status`. Codex doesn't: its
    /// sign-in's id token says, read here for the email and plan only.
    static func identify(_ account: PlanAccount, binary: String, env: [String: String], permit: ProviderLaunchPermit? = nil) async -> (signedIn: Bool, email: String?, plan: String?) {
        guard let permit = permit ?? ProviderConsent.shared.permit(account.cli) ?? ProviderConsent.shared.connectionPermit(account.cli), permit.valid else { return (false, nil, nil) }
        if account.cli == "cursor" { return await CursorRunner.identify(binary: binary, env: env, permit: permit) }
        if account.cli == "codex" {
            let (code, _) = await Shell.run(binary, ["login", "status"], env: env, permit: permit)
            guard permit.valid else { return (false, nil, nil) }
            let signedIn = code == 0
            let home = account.home.map { URL(fileURLWithPath: $0) } ?? AgentSetup.home.appendingPathComponent(".codex")
            let who = await read("codex", env: ["CODEX_HOME": home.path])
            guard permit.valid else { return (false, nil, nil) }
            return (signedIn, who.email, who.plan)
        }
        let (code, output) = await Shell.run(binary, ["auth", "status"], env: env, permit: permit)
        guard permit.valid else { return (false, nil, nil) }
        guard let status = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        else { return (code == 0, nil, nil) }
        let config = account.home.map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") } ?? AgentSetup.claudeConfig
        let remembered = (try? Data(contentsOf: config))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["oauthAccount"] as? [String: Any]
        return (status["loggedIn"] as? Bool ?? false,
                status["email"] as? String ?? remembered?["emailAddress"] as? String,
                status["subscriptionType"] as? String)
    }

    // MARK: - signing in without replacing an account

    /// Renewals write to a fresh folder. Neither cancellation nor a
    /// different identity can replace the account whose login was renewed.
    func prepareSignIn(_ cli: String, replacing id: String? = nil) -> PlanAccount {
        if cli == "cursor" { return account("cursor") ?? PlanAccount(id: "cursor", cli: "cursor") }
        // A first-ever login can still connect the CLI on this Mac. Once
        // its identity is known, every renewal gets a separate folder.
        if let first = account(id), first.email == nil, first.home == nil { return first }
        let id = cli + "." + UUID().uuidString.lowercased()
        return PlanAccount(id: id, cli: cli, home: Self.make(cli, id: id).path)
    }

    /// Remember even a signed-out identity before starting OAuth.
    func remember(_ account: PlanAccount, binary: String, base: [String: String], permit: ProviderLaunchPermit? = nil) async {
        let authority = consent ?? ProviderConsent.shared
        guard let permit = permit ?? authority.permit(account.cli) ?? authority.connectionPermit(account.cli), permit.valid else { return }
        let who = await Self.identify(account, binary: binary, env: env(account, base: base), permit: permit)
        guard permit.valid, self.account(account.id) == account else { return }
        var current = account
        current.email = who.email ?? account.email
        current.plan = settled(account.id, token: who.plan) ?? account.plan
        put(current)
        if who.signedIn { signedOut.remove(account.id) } else { signedOut.insert(account.id) }
        save()
    }

    /// The same identity renews its stable slot; a different one joins the
    /// pool. Unknown identity never overwrites a known account.
    @discardableResult
    func acceptSignIn(_ candidate: PlanAccount, replacing id: String) -> PlanAccount {
        identityChanges[id, default: 0] += 1
        identityChanges[candidate.id, default: 0] += 1
        // A new sign-in's token is fresh: what it says stands.
        let dropped = [id, candidate.id].compactMap { heardPlans.removeValue(forKey: $0) }
        if !dropped.isEmpty { saveHeard() }
        let previous = account(id)
        let matching = candidate.email.flatMap { email in
            all(candidate.cli).first { $0.email?.lowercased() == email.lowercased() }
        }
        if var existing = matching ?? previous.flatMap({ $0.email == nil ? $0 : nil }) {
            identityChanges[existing.id, default: 0] += 1
            existing.home = candidate.home
            existing.email = candidate.email ?? existing.email
            existing.plan = candidate.plan ?? existing.plan
            if heardPlans.removeValue(forKey: existing.id) != nil { saveHeard() }
            put(existing)
            signedOut.remove(existing.id)
            asked[existing.id] = nil
            save()
            return existing
        }
        extras.append(candidate)
        signedOut.remove(candidate.id)
        save()
        return candidate
    }

    private func put(_ account: PlanAccount, semanticChange: Bool = true) {
        // Passive metadata writeback must not invalidate another projection
        // of the same read. Login/logout/key changes still invalidate it.
        if semanticChange { identityChanges[account.id, default: 0] += 1 }
        if account.usual { usual[account.cli] = account }
        else if let index = extras.firstIndex(where: { $0.id == account.id }) { extras[index] = account }
    }

    /// An unsuccessful login's fresh folder is the only one discarded.
    func discardSignIn(_ candidate: PlanAccount, binary: String, base: [String: String], permit: ProviderLaunchPermit? = nil) async {
        guard permit?.valid ?? true else { return }
        await Self.forget(candidate, binary: binary, env: env(candidate, base: base), permit: permit)
    }

    // MARK: - adding and removing

    /// The CLI's usual folder, where the extra ones link back to.
    private static func usualHome(_ cli: String) -> URL {
        AgentSetup.home.appendingPathComponent(cli == "codex" ? ".codex" : ".claude")
    }

    /// A new account's folder: its own sign-in and settings, the usual
    /// folder's conversations and instructions.
    private static func make(_ cli: String, id: String) -> URL {
        let home = Store.file("plans/" + id)
        let manager = FileManager.default
        try? manager.createDirectory(at: home, withIntermediateDirectories: true)
        let usual = usualHome(cli)
        let shared = cli == "codex" ? ["sessions", "config.toml", "AGENTS.md"] : ["projects", "settings.json", "CLAUDE.md", "skills"]
        let folders: Set<String> = ["sessions", "projects"]
        for name in shared {
            let target = cli == "codex" && Store.testing && name == "sessions"
                ? Store.file("codex/sessions") : usual.appendingPathComponent(name)
            if folders.contains(name) { try? manager.createDirectory(at: target, withIntermediateDirectories: true) }
            guard manager.fileExists(atPath: target.path) else { continue }
            try? manager.createSymbolicLink(at: home.appendingPathComponent(name), withDestinationURL: target)
        }
        return home
    }

    /// Add Account: a folder of its own, the CLI's sign-in in a private tab
    /// (so the account the site already knows you by doesn't answer), and
    /// the new one last in the order.
    func add(_ cli: String, _ browser: Browser) {
        if cli == "cursor" { AgentSetupModel.shared.connect([cli], browser); return }
        guard adding == nil else { return }
        let authority = consent ?? ProviderConsent.shared
        authority.beginConnection(cli)
        guard let permit = authority.connectionPermit(cli) else { return }
        adding = cli
        step = .opening
        trouble = nil
        Task {
            defer { authority.endConnection(cli, permit: permit); adding = nil; step = nil }
            await authority.settleDisconnects()
            guard permit.valid else { return }
            let found = await Shell.find()
            guard permit.valid else { return }
            guard let binary = AgentSetupModel.binary(cli, in: found) else { return stop(Self.notAdded, browser) }
            let id = cli + "." + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
            let home = Self.make(cli, id: id)
            var account = PlanAccount(id: id, cli: cli, home: home.path)
            let env = env(account, base: found.env)
            let end = await Agents.shared.connect(cli, binary: binary, env: env, in: browser, privately: true, permit: permit) { [weak self = self] page in
                guard let self, self.adding == cli, self.step != .checking else { return }
                self.step = Step(page)
            }
            guard permit.valid else { return }
            // Canceled: its folder goes, and nothing is said.
            guard end != .canceled else { return await Self.forget(account, binary: binary, env: env, permit: permit) }
            step = .checking
            if let settings = SettingsWindow.shared.window, settings.isVisible { settings.makeKeyAndOrderFront(nil) }
            NSApp.activate()
            let who = end == .signedIn ? await Self.identify(account, binary: binary, env: env, permit: permit) : (signedIn: false, email: nil, plan: nil)
            guard permit.valid else { return }
            guard who.signedIn else {
                await Self.forget(account, binary: binary, env: env, permit: permit)
                return stop(Shell.blocked(binary) ? AgentSetupModel.blocked(cli) : Self.notAdded, browser)
            }
            if let email = who.email, all(cli).contains(where: { $0.email?.lowercased() == email.lowercased() }) {
                await Self.forget(account, binary: binary, env: env, permit: permit)
                return stop(Self.already(email), browser)
            }
            account.email = who.email
            account.plan = who.plan
            extras.append(account)
            // Plans before keys: a key is billed per use.
            var ids = all(cli).map(\.id).filter { $0 != id }
            ids.insert(id, at: ids.firstIndex { self.account($0)?.keyed == true } ?? ids.endIndex)
            order = ids + order.filter { !$0.hasPrefix(cli) }
            save()
            authority.grant(cli)
            if self === PlanAccounts.shared { AgentSetupModel.shared.didConnect(cli) }
        }
    }

    /// Said in its row until the next press; in the corner too only when
    /// Settings isn't up to show it.
    private func stop(_ words: String, _ browser: Browser) {
        trouble = words
        if SettingsWindow.shared.window?.isVisible != true { browser.announce(words, mark: "exclamationmark.triangle") }
    }

    func cancelAdding() {
        guard let cli = adding else { return }
        (consent ?? ProviderConsent.shared).endConnection(cli)
        Agents.shared.cancelConnect(cli, privately: true)
    }

    /// Its private tab in front again.
    func showSignIn(_ cli: String) {
        guard adding == cli else { return }
        Agents.shared.showSignIn(cli, privately: true)
    }

    // MARK: - API keys

    static let keyHere = "This key is already here."

    /// Add API Key: checked once with its provider, then an account of its
    /// own, last in the order. Nil when it is in; else why not.
    func addKey(_ cli: String, _ key: String) async -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if (cli == "claude" && AgentKey.claude() == key) || all(cli).contains(where: { $0.keyed && AgentKey.secret($0.id) == key }) {
            return Self.keyHere
        }
        let id = cli + ".key." + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        var account = PlanAccount(id: id, cli: cli, tail: AgentKey.tail(key))
        let authority = consent ?? ProviderConsent.shared
        authority.beginConnection(cli)
        guard let permit = authority.connectionPermit(cli) else { return AgentKey.refused(cli) }
        defer { authority.endConnection(cli, permit: permit) }
        await authority.settleDisconnects()
        guard permit.valid else { return AgentKey.refused(cli) }
        if let trouble = await take(&account, key, permit: permit) { return trouble }
        guard permit.valid else { return AgentKey.refused(cli) }
        AgentKey.keep(id, key: key)
        extras.append(account)
        order = order.filter { !$0.hasPrefix(cli) } + all(cli).map(\.id)
        signedOut.remove(id)
        save()
        authority.grant(cli)
        return nil
    }

    /// Replace Key: the same account, the same place in the order, a new key.
    func replaceKey(_ id: String, _ key: String) async -> String? {
        guard var account = account(id), account.keyed else { return nil }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if all(account.cli).contains(where: { $0.id != id && $0.keyed && AgentKey.secret($0.id) == key }) { return Self.keyHere }
        let authority = consent ?? ProviderConsent.shared
        authority.beginConnection(account.cli)
        guard let permit = authority.connectionPermit(account.cli) else { return AgentKey.refused(account.cli) }
        defer { authority.endConnection(account.cli, permit: permit) }
        await authority.settleDisconnects()
        guard permit.valid else { return AgentKey.refused(account.cli) }
        if let trouble = await take(&account, key, permit: permit) { return trouble }
        guard permit.valid else { return AgentKey.refused(account.cli) }
        AgentKey.keep(id, key: key)
        account.tail = AgentKey.tail(key)
        put(account)
        quotas[id] = nil
        signedOut.remove(id)
        save()
        saveQuotas()
        authority.grant(account.cli)
        return nil
    }

    /// The provider takes the key, and Codex's own login keeps it in the
    /// account's folder.
    private func take(_ account: inout PlanAccount, _ key: String, permit: ProviderLaunchPermit) async -> String? {
        switch await AgentKey.check(account.cli, key, permit: permit) {
        case .refused: return AgentKey.refused(account.cli)
        case .unreachable: return AgentKey.unreachable(account.cli)
        case .taken: break
        }
        guard permit.valid else { return AgentKey.refused(account.cli) }
        guard account.cli == "codex" else { return nil }
        let found = await Shell.find()
        guard let binary = AgentSetupModel.binary("codex", in: found) else { return AgentKey.unsaved("codex") }
        let fresh = account.home == nil
        if fresh { account.home = Self.make("codex", id: account.id).path }
        guard await AgentKey.codexLogin(binary: binary, key: key, env: env(account, base: found.env), permit: permit) else {
            if fresh, let home = account.home { try? FileManager.default.removeItem(atPath: home) }
            return AgentKey.unsaved("codex")
        }
        return nil
    }

    /// Move Up and Move Down, among its agent's accounts.
    func move(_ id: String, by step: Int) {
        guard let cli = account(id)?.cli else { return }
        var ids = all(cli).map(\.id)
        guard let at = ids.firstIndex(of: id), ids.indices.contains(at + step) else { return }
        ids.swapAt(at, at + step)
        order = order.filter { !ids.contains($0) } + ids
        save()
    }

    func remove(_ id: String) {
        guard let account = extras.first(where: { $0.id == id }) else { return }
        identityChanges[id, default: 0] += 1
        if account.keyed { AgentKey.keep(id, key: nil) }
        extras.removeAll { $0.id == id }
        order.removeAll { $0 == id }
        quotas[id] = nil
        signedOut.remove(id)
        if heardPlans.removeValue(forKey: id) != nil { saveHeard() }
        save()
        saveQuotas()
        guard let home = account.home else { return }
        if account.cli == "codex" {
            let root = Store.file("plans").standardizedFileURL.resolvingSymlinksInPath().path + "/"
            if URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) { try? FileManager.default.removeItem(atPath: home) }
            return
        }
        Task {
            let found = await Shell.find()
            guard let binary = AgentSetupModel.binary(account.cli, in: found) else { return }
            await Self.forget(account, binary: binary, env: env(account, base: found.env))
        }
    }

    /// Its sign-in and its folder go; the links in it only. Claude Code
    /// keeps its sign-in in the keychain, so it is signed out first; Codex
    /// keeps it in the folder's auth.json, which goes with the folder and
    /// is never logged out, so no sign-in anywhere else is revoked with it.
    private static func forget(_ account: PlanAccount, binary: String, env: [String: String], permit: ProviderLaunchPermit? = nil) async {
        guard permit?.valid ?? true else { return }
        guard let home = account.home else { return }
        if account.cli == "claude" { _ = await Shell.run(binary, ["auth", "logout"], env: env, permit: permit) }
        ProviderLaunchPermit.atomic {
            guard permit?.valid ?? true else { return }
            try? FileManager.default.removeItem(atPath: home)
        }
    }
}
