import Foundation

// How a chat on an agent starts, decided in one place for everyone who
// asks: the launcher (Agents.launch, and the helpers that run the same CLI
// without a chat: WarmClaude, PlanText, ThreadNamer, LinkFolders) and
// readiness (AgentSetupModel.look, behind Agents.ready and the composer's
// Return). Readiness used to decide it apart, from files alone, while the
// launcher read the login shell's PATH and exported token, and every edit
// to one side brought #1687 back: Return in ⌘J opened Settings › AI for a
// Claude a chat would have run on (0.46.11, again after 8aeb35e5).
//
// Now "ready" is a projection of this resolution: the same environment
// (AgentLaunch.environment, the very Shell.Found the launcher's next
// Shell.find() answers with), the same copy of the CLI, the same account
// order and the same per-account environment (PlanAccounts.environment).
// Only the last step differs, and has to: a task asks the CLI itself
// (`auth status`), while a look never runs an agent binary (macOS checks a
// binary as it runs, and an old copy it flags would look like Yab's doing)
// and reads the same account's files, keychain presence and environment
// instead (PlanAccounts.read). AgentLaunchReadinessTests holds the two to
// one answer in every way a person can be signed in.

/// How a task on one agent starts: the copy of its CLI, the account it
/// starts on, and the environment that copy runs in.
struct AgentLaunch: Equatable {
    let cli: String
    let binary: String
    /// Nil only for an agent without accounts (Gemini).
    let account: PlanAccount?
    let env: [String: String]

    /// Where Claude Code takes its sign-in from first: an API key, the
    /// token `claude setup-token` has you export, or its own files.
    enum Token: Equatable { case key, exported, files }

    var token: Token {
        guard cli == "claude" else { return .files }
        if !(env[AgentKey.anthropic] ?? "").isEmpty { return .key }
        if !(env[Shell.claudeToken] ?? "").isEmpty { return .exported }
        return .files
    }

    /// The account's own config folder; nil for the CLI's usual one.
    var configDir: String? { env[cli == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] }
}

@MainActor
extension AgentLaunch {
    /// The environment every task runs in: the login shell's PATH and an
    /// exported CLAUDE_CODE_OAUTH_TOKEN over what the files say, and the
    /// key Claude was connected with (Shell.find). Cached, so a look that
    /// asks for it afresh is what the next task starts from.
    static func environment(fresh: Bool = false) async -> Shell.Found {
        await Shell.find(fresh: fresh, resolvingLogin: true)
    }

    /// Whether a look decides readiness in that environment: once any agent
    /// is connected in Yab, as a task on it would run. Nothing unconnected
    /// runs the login shell to be looked at (Cortex, 8aeb35e5), and a
    /// probe's stand-in Claude or Codex (YAB_AGENT_CLAUDE) is signed in by
    /// its harness. Only a person's ask or a task looks at all
    /// (AgentSetupModel.asked): never the launch, never a timer.
    static func needsTerminal(_ consent: ProviderConsent) -> Bool {
        terminalCLIs.contains { cli in
            consent.allows(cli) && (AgentFixture.requested || !byHarness(cli))
        }
    }

    /// A probe's stand-in Claude or Codex, signed in by its harness.
    static func byHarness(_ cli: String) -> Bool {
        ["claude", "codex"].contains(cli) && ProviderConsent.standIns().contains(cli)
    }

    /// The agents whose readiness is a projection of their launch here:
    /// every one Yab connects (AgentSetupModel.clis).
    nonisolated static let terminalCLIs = ["claude", "codex", "cursor", "gemini"]

    /// How a task on `cli` starts in `found`: its copy, the first account
    /// with room in your order (PlanAccounts.pick), and that account's
    /// environment with its secrets. Nil when the agent isn't on this Mac.
    static func resolve(_ cli: String, in found: Shell.Found, plans: PlanAccounts? = nil,
                        skipping: Set<String> = []) -> AgentLaunch? {
        let plans = plans ?? .shared
        guard let binary = binary(cli, in: found) else { return nil }
        return on(account(cli, plans: plans, skipping: skipping), cli: cli, binary: binary, in: found, plans: plans)
    }

    /// The same resolution as a look sees it: the same copy, account and
    /// environment, less a keyed account's secret, which a look never loads.
    static func look(_ cli: String, in found: Shell.Found, plans: PlanAccounts? = nil) -> AgentLaunch? {
        let plans = plans ?? .shared
        guard let binary = binary(cli, in: found) else { return nil }
        let account = account(cli, plans: plans, skipping: [])
        return AgentLaunch(cli: cli, binary: binary, account: account,
                           env: account.map { PlanAccounts.environment($0, base: found.env, secret: nil) } ?? found.env)
    }

    /// The account a task starts on; Gemini has none of Yab's (its sign-in
    /// is the CLI's own, in Yab's profile for it, GeminiAccount).
    private static func account(_ cli: String, plans: PlanAccounts, skipping: Set<String>) -> PlanAccount? {
        cli == "gemini" ? nil : plans.pick(cli, skipping: skipping)
    }

    /// The copy of `cli` a task runs: the newest Shell.find saw (AgentCopies).
    nonisolated static func binary(_ cli: String, in found: Shell.Found) -> String? {
        AgentSetupModel.binary(cli, in: found)
    }

    /// Whether a task on `cli` would find its copy, from what is known
    /// without asking anything: the environment tasks run in, once a look
    /// or a task has resolved it. Before that, files alone can only say
    /// yes: a connected agent they don't show may be on the login shell's
    /// PATH, and its task resolves it, so it counts as here (a chat set to
    /// Claude fell to another plan, as #1687 did). Nil: nothing looked for.
    static func here(_ cli: String, consent: ProviderConsent? = nil) -> Bool? {
        let consent = consent ?? .shared
        return here(cli, terminal: Shell.cachedTerminal, files: Shell.cached, consent: consent)
    }

    static func here(_ cli: String, terminal: Shell.Found?, files: Shell.Found?, consent: ProviderConsent) -> Bool? {
        if let terminal { return binary(cli, in: terminal) != nil }
        guard let files else { return nil }
        return binary(cli, in: files) != nil || (terminalCLIs.contains(cli) && consent.allows(cli))
    }

    /// The same, on an account already chosen (a sign-in's, the next one
    /// with room).
    static func on(_ account: PlanAccount?, cli: String, binary: String, in found: Shell.Found,
                   plans: PlanAccounts? = nil) -> AgentLaunch {
        let plans = plans ?? .shared
        return AgentLaunch(cli: cli, binary: binary, account: account, env: plans.env(account, base: found.env))
    }

    /// The environment a look reads an account's sign-in in: the one its
    /// task runs in, without a keyed account's secret (a look never loads
    /// one; whether it is kept says, AgentKey.hasSecret).
    static func lookEnvironment(_ account: PlanAccount, in found: Shell.Found) -> [String: String] {
        PlanAccounts.environment(account, base: found.env, secret: nil)
    }
}
