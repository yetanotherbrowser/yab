import AppKit

/// The AI plans Yab connects, one row each: what people read, the tool it
/// runs, its mark, how it installs and signs in, and its models. A new plan
/// is a row here rather than a `cli == "codex" ? … : …` in every view
/// (docs/cursor.md, "One table of plans").
struct AgentPlan {
    /// The CLI's id, as stored: "claude", "codex", "cursor".
    let cli: String
    /// Whose plan it signs in to, in every word people read.
    let name: String
    /// The tool Yab runs for it, only where a person types it or has it on
    /// this Mac already.
    let tool: String
    /// Its monochrome mark (Glyphs), the same in every list and header.
    let mark: String
    /// Who it downloads from while it installs.
    let maker: String
    /// It gets Yab's skill and tools and is asked for Yab by name in a
    /// terminal, so Connect ends on How to Ask. A plan that only runs
    /// inside Yab (Cursor) goes back to its row with the tick.
    let skilled: Bool
    /// The command that installs it.
    let install: String
    /// What its CLI is told to sign in.
    let signIn: [String]
    /// Its own apps, for their icons, newest first.
    let apps: [String]
    /// Its tile while no app of it is on this Mac.
    let tile: (icon: String, tint: NSColor)
    /// Its models show in a model list while it isn't connected, under a
    /// line that says where to connect it. Cursor's catalog is its account's,
    /// so it shows only once connected.
    let listedAway: Bool
    /// The plans it runs on, for the welcome.
    let needs: String
    /// Where the login shell found it.
    let binary: KeyPath<Shell.Found, String?>
    /// Whether Connect put it in place.
    let connected: KeyPath<AgentSetup.Status, Bool>
    /// It is offered through Settings' Connect and the welcome. Gemini's
    /// own profile and Google sign-in remain managed by GeminiAccount.
    var connects = true
    /// It may use Yab's browser tools in a task. Gemini doesn't until it is
    /// proven to reach nothing but them (docs/gemini.md).
    var tools = true

    static let claude = AgentPlan(
        cli: "claude", name: "Claude", tool: "Claude Code", mark: "brand.claude", maker: "Anthropic", skilled: true,
        install: "curl -fsSL https://claude.ai/install.sh | bash", signIn: ["auth", "login", "--claudeai"],
        apps: ["com.anthropic.claudefordesktop"], tile: ("brand.claude", .systemOrange), listedAway: true,
        needs: "Claude needs Pro, Max, Team or Enterprise.",
        binary: \.claude, connected: \.claude)
    static let codex = AgentPlan(
        cli: "codex", name: "ChatGPT", tool: "Codex", mark: "brand.openai", maker: "OpenAI", skilled: true,
        install: "npm install -g @openai/codex", signIn: ["login"],
        apps: ["com.openai.codex", "com.openai.chat"], tile: ("brand.openai", .systemPurple), listedAway: true,
        needs: "ChatGPT works on Plus, Pro, Business, Enterprise and Edu. Free and Go may too, with low limits.",
        binary: \.codex, connected: \.codex)
    static let cursor = AgentPlan(
        cli: "cursor", name: "Cursor", tool: "Cursor CLI", mark: "brand.cursor", maker: "Cursor", skilled: false,
        install: "curl -fsSL https://cursor.com/install | bash", signIn: ["login"],
        apps: ["com.todesktop.230313mzl4w4u92"], tile: ("brand.cursor", .systemBlue), listedAway: false,
        needs: "Cursor runs on your Cursor plan, within its limits.",
        binary: \.cursor, connected: \.cursor)

    static let gemini = AgentPlan(
        cli: "gemini", name: "Gemini", tool: "Antigravity CLI", mark: "brand.gemini", maker: "Google", skilled: false,
        install: "curl -fsSL https://antigravity.google/cli/install.sh | bash", signIn: [],
        apps: [], tile: ("brand.gemini", .systemIndigo), listedAway: false,
        needs: "Gemini runs on your Google AI plan, within its limits.",
        binary: \.gemini, connected: \.gemini, tools: GeminiSupport.toolsProven)

    static let opencode = AgentPlan(
        cli: "opencode", name: "OpenCode", tool: "OpenCode CLI", mark: "brand.opencode", maker: "OpenCode", skilled: false,
        install: "curl -fsSL https://opencode.ai/install | bash", signIn: ["auth", "login"],
        apps: [], tile: ("brand.opencode", .systemTeal), listedAway: false,
        needs: "OpenCode runs on your OpenCode plan, within its limits.",
        binary: \.opencode, connected: \.opencode)

    /// In the order every list shows them.
    static let all = [claude, codex, cursor, gemini, opencode]
    static let clis = all.map(\.cli)
    /// The plans Settings' Connect and the welcome connect.
    static let connectable = all.filter(\.connects)

    static func of(_ cli: String?) -> AgentPlan? { all.first { $0.cli == cli } }
    /// A plan's CLI, not this Mac's model or the default.
    static func isPlan(_ cli: String?) -> Bool { of(cli) != nil }

    /// "Claude Plan", the model picker's group.
    var group: String { name + " Plan" }

    /// What it can be started on, as the model lists show them.
    @MainActor var models: [AgentModel] {
        switch cli {
        case "cursor": CursorRunner.models
        case "opencode": OpenCodeRunner.models
        case "codex": AgentModels.codex()
        case "gemini": GeminiAccount.shared.models
        default: AgentModels.claude
        }
    }
}
