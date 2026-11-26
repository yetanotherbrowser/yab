import Foundation
import Testing
import SyncKit
@testable import Fast

// A step's words, the one table the chat, the dock and the task page read
// (StepWords): every tool has its three forms and a mark, what it was about
// comes out of its input, another server's tool is named by its server, and
// older notes are put in the same words.

@MainActor
struct StepWordsTests {
    static func item(_ tool: String, _ input: [String: Any]) -> ChatItem {
        ChatItem.claude(["type": "tool_use", "id": "t", "name": tool, "input": input], message: "m")!
    }

    static func words(_ tool: String, _ input: [String: Any] = [:]) -> StepWords {
        StepWords.of(item(tool, input))
    }

    @Test func everyToolHasItsVerbsAndAMark() {
        let open = Self.words("mcp__yab-browser__open", ["url": "https://github.com/notifications"])
        #expect(open.line(.running) == "Opening github.com")
        #expect(open.line(.done) == "Opened github.com")
        #expect(open.line(.failed) == "Couldn\u{2019}t open github.com")
        #expect(open.site == "github.com")

        let read = Self.words("Read", ["file_path": "/Users/me/fast/Sources/Fast/ChatTranscript.swift"])
        #expect(read.line(.done) == "Read ChatTranscript.swift")
        #expect(read.art == .readFile && read.middle)

        let grep = Self.words("Grep", ["pattern": "ChatStepMark", "path": "/Users/me/fast/Sources"])
        #expect(grep.line(.running) == "Searching for \u{201C}ChatStepMark\u{201D} in Sources")
        #expect(grep.art == .search)

        let glob = Self.words("Glob", ["pattern": "**/*.swift"])
        #expect(glob.line(.done) == "Listed **/*.swift")
        #expect(glob.art == .folder)

        let search = Self.words("WebSearch", ["query": "WebKit 26 release notes"])
        #expect(search.line(.running) == "Searching the web for \u{201C}WebKit 26 release notes\u{201D}")

        let bash = StepWords.of(Self.item("Bash", ["command": "swift build 2>&1 | tail -3"]))
        #expect(bash.line(.done) == "Ran swift build 2>&1 | tail -3")
        #expect(bash.art == .command && bash.middle)

        #expect(Self.words("mcp__yab-browser__mail_search", ["query": "from:alex invoice"]).line(.done) == "Searched mail for \u{201C}from:alex invoice\u{201D}")
        #expect(Self.words("mcp__yab-browser__mail_labels", ["do": "list"]).line(.done) == "Read your labels")
        #expect(Self.words("mcp__yab-browser__mail_labels", ["do": "delete", "labels": ["a", "b", "c"]]).line(.running) == "Deleting 3 labels")
        #expect(Self.words("mcp__yab-browser__mail_labels", ["do": "delete", "labels": ["Receipts"]]).line(.done) == "Deleted the label \u{201C}Receipts\u{201D}")
        #expect(Self.words("mcp__yab-browser__mail_labels", ["do": "rename", "label": "Work", "to": "Projects"]).line(.failed) == "Couldn\u{2019}t rename the label \u{201C}Work\u{201D}")
        #expect(Self.words("mcp__yab-browser__mail_act", ["thread": "a|b", "do": "unsubscribe"]).line(.done) == "Unsubscribed")
        #expect(Self.words("mcp__yab-browser__mail_act", ["thread": "a|b", "do": "remind", "until": "3"]).line(.running) == "Setting a reminder")
        #expect(Self.words("mcp__yab-browser__mail_act", ["thread": "a|b", "do": "archive"]).line(.done) == "Tidied mail")
        #expect(Self.words("mcp__yab-browser__mail_send", ["draft": "a|new:1", "undo": true]).line(.done) == "Took back the mail")
        #expect(Self.words("mcp__yab-browser__mail_list", ["list": "Kept"]).line(.done) == "Read \u{201C}Kept\u{201D}")
        #expect(Self.words("mcp__yab-browser__mail_list").line(.done) == "Looked over your mail")
        #expect(Self.words("mcp__yab-browser__mail_accounts", ["do": "add", "address": "me@icloud.com"]).line(.running) == "Connecting me@icloud.com")
        #expect(Self.words("mcp__yab-browser__mail_accounts").line(.done) == "Read your mail accounts")
        #expect(Self.words("mcp__yab-browser__calendar_free", ["minutes": 45]).line(.done) == "Found free time")
        #expect(Self.words("mcp__yab-browser__download", ["tab": "zz"]).art == .download)
        #expect(Self.words("mcp__yab-browser__pdf", ["tab": "zz"]).running == "Saving as PDF")
        #expect(Self.words("mcp__yab-browser__autofill", ["what": "address"]).line(.done) == "Filled the address")
        #expect(Self.words("mcp__yab-browser__run", ["code": "x"]).art == .code)
        #expect(Self.words("mcp__yab-browser__sign_in", ["tab": "zz"]).art == .key)
        #expect(Self.words("mcp__yab-browser__watch", ["url": "https://mail.google.com/x"]).line(.running) == "Watching mail.google.com")
        // No step falls to the raw name or to the old default mark.
        for tool in ["drag", "dialog", "upload", "sign_in", "handoff", "subagent", "subagent_wait", "mail_triage", "mail_read", "mail_draft", "mail_act", "mail_labels", "mail_list", "mail_accounts", "calendar_free", "messages", "send_message", "computer_access"] {
            let said = Self.words("mcp__yab-browser__" + tool)
            #expect(!said.running.hasPrefix("Using"), "\(tool) reads \(said.running)")
            #expect(said.art != .point || tool == "hover", "\(tool) wears the default mark")
        }
    }

    @Test func bookkeepingIsQuietAndAsksWait() {
        for tool in ["memory_search", "memory_read", "remember", "history", "skill", "name", "profile", "form_answers", "wait", "tabs"] {
            #expect(Self.words("mcp__yab-browser__" + tool).quiet, "\(tool) should stay off the list")
        }
        let ask = Self.words("mcp__yab-browser__ask", ["question": "Reply to Alex now, or later?", "options": ["Now", "Later"]])
        #expect(ask.asks && ask.art == .hand)
        #expect(ask.line(.running) == "Asking you Reply to Alex now, or later?")
        let handoff = Self.item("mcp__yab-browser__handoff", ["tab": "zz", "reason": "Sign in to GitHub"])
        #expect(StepWords.of(handoff).line(.running) == "Waiting for you: Sign in to GitHub")
        var skipped = handoff
        skipped.text = "skipped"
        #expect(StepWords.of(skipped).done == "You skipped:")
        var finished = handoff
        finished.text = "done"
        #expect(StepWords.of(finished).done == "You finished:")
    }

    @Test func whatAStepWasAboutComesFromItsInput() {
        #expect(ChatItem.about("navigate", ["tab": "a", "url": "back"]) == "nav:back")
        #expect(Self.words("mcp__yab-browser__navigate", ["url": "back"]).line(.done) == "Went back")
        #expect(ChatItem.about("press", ["tab": "a", "keys": "Meta+a"]) == "keys:Meta+a")
        let press = Self.words("mcp__yab-browser__press", ["keys": "Tab Tab Enter"])
        #expect(press.keys == "Tab Tab Enter")
        #expect(press.line(.done) == "Pressed Tab Tab Return")
        #expect(ChatItem.about("scroll", ["dy": -300]) == "up")
        #expect(ChatItem.about("dialog", ["accept": false]) == "Cancel")
        #expect(ChatItem.about("upload", ["files": ["/tmp/a/resume.pdf", "/tmp/b.png"]]) == "resume.pdf and 1 more")
        #expect(ChatItem.about("type", ["text": "is:unread"]) == "\u{201C}is:unread\u{201D}")
    }

    @Test func aMemoryStepSaysItsFactWithoutMarkdown() {
        let line = Self.words("mcp__yab-browser__remember", ["file": "preferences", "text": "- **Prefers** dark mode on [[github]] and `Arc`"])
        #expect(line.line(.running) == "Remembering \u{201C}Prefers dark mode on github and Arc\u{201D}")
        let page = "---\nname: coffee-orders\ndescription: How they take their **coffee**\n---\n## Orders\n- Flat white"
        #expect(Self.words("mcp__yab-browser__remember", ["file": "coffee", "text": page]).object == "\u{201C}How they take their coffee\u{201D}")
        let entry = "## 2026-10-09\n\n- Booked _the_ table at [Tabelog](https://tabelog.com) for 4"
        #expect(Self.words("mcp__yab-browser__remember", ["file": "episodic", "text": entry]).object == "\u{201C}Booked the table at Tabelog for 4\u{201D}")
        #expect(Self.words("mcp__yab-browser__remember", ["file": "people", "text": "## Alex"]).object == "\u{201C}Alex\u{201D}")
        // A chat kept before: the markdown, cut and quoted, as its detail.
        let kept = ChatItem(id: "a", kind: .tool, name: "remember", detail: "\u{201C}## Work\n- **Standup** at 10\u{201D}")
        #expect(StepWords.of(kept).object == "\u{201C}Standup at 10\u{201D}")
        // Prose loses its marks; what was typed keeps them.
        #expect(ChatItem.about("ask", ["question": "Send **this** to `Alex`?"]) == "Send this to Alex?")
        #expect(ChatItem.about("type", ["text": "**bold**"]) == "\u{201C}**bold**\u{201D}")
        #expect(ChatItem.prose("snake_case_name and 2*3*4") == "snake_case_name and 2*3*4")
    }

    @Test func anotherServersToolIsNamedByItsServer() {
        let linear = Self.item("mcp__linear__create_issue", ["title": "Flaky WebKit test on CI"])
        #expect(linear.name == "linear/create_issue")
        let words = StepWords.of(linear)
        #expect(words.line(.done) == "Created an issue in Linear \u{201C}Flaky WebKit test on CI\u{201D}" || words.line(.done) == "Created an issue in Linear Flaky WebKit test on CI")
        #expect(words.site == "linear.app")
        #expect(Self.item("mcp__yab-browser__open", ["url": "https://a.com"]).name == "open")
        let unknown = StepWords.of(Self.item("mcp__acme__frobnicate_widgets", [:]))
        #expect(unknown.running == "Using Acme")
        #expect(unknown.art == .mcp)
        #expect(StepWords.server("github", "list_issues", object: "").done == "Listed issues in GitHub")
    }

    /// "a" or "an" by how the noun is said, and a tool named with two verbs
    /// says both: Linear's get_user was "Got an user", and GitHub's
    /// create_or_update_file "Created an or update file".
    @Test func anotherServersToolIsSaidInEnglish() {
        #expect(StepWords.server("linear", "get_user", object: "").done == "Got a user in Linear")
        #expect(StepWords.server("acme", "get_hour", object: "").done == "Got an hour in Acme")
        #expect(StepWords.server("figma", "get_image", object: "").done == "Got an image in Figma")
        let both = StepWords.server("github", "create_or_update_file", object: "")
        #expect(both.running == "Creating or updating a file in GitHub")
        #expect(both.done == "Created or updated a file in GitHub")
        #expect(both.failed == "Couldn\u{2019}t create or update a file in GitHub")
    }

    @Test func commandsAndTitlesReadAsWords() {
        #expect(StepWords.command("/bin/zsh -lc 'git status'") == "git status")
        #expect(StepWords.command("bash -lc \"npm test\"") == "npm test")
        #expect(StepWords.command("ls -la") == "ls -la")
        #expect(StepWords.title("Sign in to GitHub \u{00B7} GitHub", host: "github.com") == "Sign in to GitHub")
        #expect(StepWords.title("Notifications | GitHub", host: "github.com") == "Notifications")
        #expect(StepWords.title("Home - Linear", host: "linear.app") == "Home")
        #expect(StepWords.title("Pick one - or the other", host: "example.com") == "Pick one - or the other")
        #expect(StepWords.title("", host: "example.com") == nil)
    }

    @Test func olderNotesArePutInTheSameWords() {
        #expect(StepWords.say("click \u{00B7} github.com", name: "Claude Code") == "Clicking on github.com")
        #expect(StepWords.say("snapshot \u{00B7} github.com", name: "Claude Code") == "Reading github.com")
        #expect(StepWords.say("read \u{00B7} github.com", name: "Claude Code") == "Reading github.com")
        #expect(StepWords.say("navigate \u{00B7} github.com", name: "Claude Code") == "Going to github.com")
        #expect(StepWords.say("press Enter", name: "Claude Code") == "Pressing Return")
        #expect(StepWords.say("", name: "Codex") == "Codex is working")
        #expect(StepWords.say("Opening github.com", name: "Codex") == "Opening github.com")
        #expect(StepWords.say("Steered: do it faster", name: "Codex") == "Heard what you added")
        #expect(Agents.step("mcp__yab-browser__open", ["url": "https://github.com"]) == "Opening github.com")
        #expect(Agents.step("Bash", ["command": "ls"]) == "Running ls")
    }

    @Test func failuresSayWhatWentWrong() {
        #expect(Chat.failure("API Error: 500 Internal server error", agent: "Claude Code") == "Claude Code\u{2019}s server failed partway.")
        #expect(Chat.failure("Claude Code stopped (1).", agent: "Claude Code") == "Claude Code stopped before it finished.")
        #expect(Chat.failure("You've hit your usage limit", agent: "Codex") == "Codex is out of room on this plan for now.")
        #expect(Chat.failure("something odd", agent: "Codex") == "Codex couldn\u{2019}t finish.")
    }

    @Test func waitingOnYouIsNotWork() {
        let start = Date(timeIntervalSince1970: 1_000)
        func at(_ s: Double) -> Date { start.addingTimeInterval(s) }
        var asked = ChatItem(id: "q", kind: .asked, text: "go", state: .done)
        asked.began = at(0)
        var open = ChatItem(id: "o", kind: .tool, name: "open", detail: "a.com", state: .done)
        open.began = at(1); open.ended = at(3)
        var ask = ChatItem(id: "a", kind: .tool, name: "ask", detail: "Now or later?", state: .done)
        ask.began = at(3); ask.ended = at(63)
        var said = ChatItem(id: "m", kind: .message, text: "Done.", state: .done)
        said.began = at(70)
        let turn = [asked, open, ask, said]
        #expect(Chat.waited(turn) == 60)
        #expect(Chat.worked(turn) == 10)
    }

    @Test func thePlanIsReadWithWhereEachStepStands() {
        let todo = Self.item("TodoWrite", ["todos": [["content": "Read notifications", "status": "completed"],
                                                      ["content": "Draft replies", "status": "in_progress"],
                                                      ["content": "Summarize", "status": "pending"]]])
        #expect(todo.kind == .plan)
        #expect(todo.text == "[x] Read notifications\n[>] Draft replies\n[ ] Summarize")
        let chat = Chat(id: "c", title: "t", began: .field, cli: "claude", items: [ChatItem(id: "q", kind: .asked, text: "go", state: .done), todo],
                        state: "running", answer: "", started: Date(), updated: Date())
        let steps = ChatPlan.steps(chat)
        #expect(steps?.count == 3)
        #expect(steps?[1] == ChatPlan.Step(text: "Draft replies", done: false, now: true))
    }

    @Test func codexExecShowsItsWorkToo() {
        let ran = ChatItem.codexExec(["id": "i1", "type": "command_execution", "command": "bash -lc 'swift test'", "aggregated_output": "error: x", "exit_code": 1, "status": "completed"], done: true)
        #expect(ran?.kind == .command && ran?.state == .failed)
        #expect(StepWords.of(ran!).line(.failed) == "Couldn\u{2019}t run swift test")
        let edit = ChatItem.codexExec(["id": "i2", "type": "file_change", "changes": [["path": "/a/b/ChatTranscript.swift", "kind": "update"]], "status": "completed"], done: true)
        #expect(edit?.detail == "ChatTranscript.swift")
        let plan = ChatItem.codexExec(["id": "i3", "type": "todo_list", "items": [["text": "One", "completed": true], ["text": "Two", "completed": false]]], done: false)
        #expect(plan?.text == "[x] One\n[ ] Two")
        let search = ChatItem.codexExec(["id": "i4", "type": "web_search", "query": "swift testing"], done: false)
        #expect(search?.state == .running && search?.detail == "\u{201C}swift testing\u{201D}")
    }

    @Test func aBoostTrialIsSaidByItsSite() {
        let files: [String: Any] = ["style.css": "ytd-reel-shelf-renderer{display:none}"]
        let trial = Self.words("mcp__yab-browser__boost", ["name": "hide-shorts", "files": files, "sites": ["www.youtube.com"], "tab": "ab12"])
        #expect(trial.line(.running) == "Trying a boost on youtube.com")
        #expect(trial.line(.done) == "Tried a boost on youtube.com")
        #expect(trial.line(.failed) == "Couldn\u{2019}t try a boost on youtube.com")
        #expect(trial.site == "youtube.com" && !trial.quiet)
        // Its answer says how many versions Yab tried, Claude's or Codex's.
        var steps = [Self.item("mcp__yab-browser__boost", ["name": "hide-shorts", "files": files, "sites": ["www.youtube.com"], "tab": "ab12"])]
        steps.answered(["type": "tool_result", "tool_use_id": "t", "content": [["type": "text", "text": #"{"shown":true,"tries":2}"#], ["type": "text", "text": "before"]]])
        #expect(StepWords.of(steps[0]).line(.done) == "Tried 2 versions on youtube.com")
        let codex = ChatItem.codex(["id": "c1", "type": "mcpToolCall", "server": "yab-browser", "tool": "boost", "status": "completed",
                                    "arguments": ["name": "hide-shorts", "sites": ["www.youtube.com"]],
                                    "result": ["content": [["type": "text", "text": #"{"tries": 1, "shown": false}"#]]]], done: true)!
        #expect(StepWords.of(codex).line(.done) == "Tried a boost on youtube.com")
        // A refused one keeps Yab's words, as Claude Code's failed calls do.
        let refused = ChatItem.codex(["id": "c2", "type": "mcpToolCall", "server": "yab-browser", "tool": "boost", "status": "failed",
                                      "arguments": ["name": "x", "sites": ["github.com"]],
                                      "result": ["content": [["type": "text", "text": "Boosts are unavailable on sign-in pages."]], "isError": true]], done: true)!
        #expect(refused.state == .failed && refused.text == "Boosts are unavailable on sign-in pages.")
        let list = Self.words("mcp__yab-browser__boosts")
        #expect(list.line(.running) == "Reading your boosts" && list.quiet)
        let read = Self.words("mcp__yab-browser__boost_read", ["name": "hide-shorts"])
        #expect(read.line(.done) == "Read the boost hide-shorts" && read.quiet)
    }

    @Test func anAnswersFirstLineLosesItsMarkdown() {
        #expect(AgentDock.firstLine("# Shorts hiding preview ready\n\nThe preview hides Shorts.") == "Shorts hiding preview ready")
        #expect(AgentDock.firstLine("**Kept** for `youtube.com`") == "Kept for youtube.com")
        #expect(AgentDock.firstLine("- one\n- two") == "one")
        #expect(AgentDock.firstLine("  \n") == nil)
    }

    /// The table as the iPhone reads it, from sync's steps alone: states
    /// as words, no tabs of this Mac's, keys by their names.
    @Test func theTableReadsTheSameFromSyncsSteps() {
        let open = StepWords.tool("open", detail: "www.timeout.com", place: nil)
        #expect(open.line("done") == "Opened timeout.com" && open.site == "timeout.com")
        #expect(StepWords.tool("WebSearch", detail: "", place: nil).line("done") == "Searched the web")
        #expect(StepWords.tool("linear/create_issue", detail: "", place: nil).line("done") == "Created an issue in Linear")
        #expect(StepWords.tool("linear/create_issue", detail: "", place: nil).site == "linear.app")
        #expect(StepWords.tool("fancy_tool", detail: "", place: nil).line("failed") == "Couldn\u{2019}t use fancy tool")
        #expect(StepWords.tool("open", detail: "a.com, b.com, c.com", place: nil).object == "a.com and 2 more")
        #expect(StepWords.tool("memory_search", detail: "", place: nil).quiet)
        #expect(StepWords.tool("snapshot", detail: "tab:ab12", place: nil).line("done") == "Read")
        let page = StepPlace(title: "Notifications | GitHub", host: "github.com", site: "github.com")
        #expect(StepWords.tool("snapshot", detail: "tab:ab12", place: page).line("done") == "Read Notifications")
        let press = StepWords.tool("press", detail: "keys:enter", place: nil)
        #expect(press.object.isEmpty && press.keys == "enter" && press.about == "Return" && press.line("done") == "Pressed Return")
        // Stopped is said where it was left: still going.
        #expect(StepWords.tool("click", detail: "", place: nil).verb("stopped") == "Clicking")
        #expect(StepWords.of(kind: "command", name: "command", detail: "/bin/zsh -lc 'swift build'", text: "").object == "swift build")
        #expect(StepWords.of(kind: "subagent", name: "spawnAgent", detail: "Check fares", text: "").line("done") == "Started a subagent Check fares")
        #expect(StepWords.of(kind: "widget", name: "", detail: "", text: "", widget: "flight_prices").line("running") == "Drawing flight prices")
        #expect(StepWords.of(kind: "message", name: "", detail: "", text: "Hi").quiet)
        // A fact kept with its markdown, as older chats have it.
        #expect(StepWords.tool("remember", detail: "\u{201C}## Trips\n- **Window** seat\u{201D}", place: nil).object == "\u{201C}Window seat\u{201D}")
        let step = SyncChatItem(id: "a:c/1", chat: "a:c", n: 1, kind: "tool", name: "Grep", detail: "\u{201C}needle\u{201D} in Sources", state: "done")
        #expect(StepWords.of(step).line("done") == "Searched for \u{201C}needle\u{201D} in Sources")
        #expect(StepWords.of(step) == StepWords.of(ChatItem(id: "1", kind: .tool, name: "Grep", detail: "\u{201C}needle\u{201D} in Sources", state: .done)))
    }
}
