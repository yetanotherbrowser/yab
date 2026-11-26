import Foundation

// A step of an agent's work in words, the same wherever it is said: on the
// Mac, the chat's rows and its live line, the dock over the page, the task
// page, a tab's card, folder tooltips, the menu bar; on the iPhone, a
// chat's work. Each step has three forms of its verb, as Codex has them,
// running ("Opening"), done ("Opened") and failed ("Couldn't open"), what it
// was about ("github.com", “WebKit 26”, ChatTranscript.swift, the button it
// pressed), and the mark it wears (StepArt). One table, so a step never
// reads one way in the chat and another on the page, or on the iPhone.
//
// What only one device knows stays there: a step done in a tab names it
// by the Mac's own id ("tab:<id>"), which the Mac reads as the page's title
// (StepPlace) and the iPhone says without; the Mac draws keys pressed,
// the iPhone says them.

/// The mark a step wears. Each device draws it its own way (StepMarks).
public enum StepArt: String, CaseIterable, Sendable {
    // With a twin in Codex: its keyframes and curves, frame for frame.
    case search, history, edit, type, skill, mcp, folder, readFile, command, wait
    // Ours alone, on its clock and curves.
    case readPage, pdf, open, click, point, scroll, shot, mail, send, hand, key, eye, robot, memory
    case download, upload, code, fill, plan, dialog, close, think, done, fail
}

/// The page a "tab:<id>" detail names, where the device knows it: as the
/// page was when the step was done in it, or as its tab is now.
public struct StepPlace: Equatable, Sendable {
    public var title: String
    public var host: String?
    /// The host whose icon stands in for the step's mark.
    public var site: String?

    public init(title: String, host: String?, site: String?) {
        self.title = title; self.host = host; self.site = site
    }
}

public struct StepWords: Equatable, Sendable {
    public var running: String
    public var done: String
    public var failed: String
    /// What it was about, as it reads; empty when the verb says it all.
    public var object = ""
    public var art: StepArt = .point
    /// The site a step went to, whose icon stands in for its mark.
    public var site: String?
    /// Yab's own bookkeeping (memory, history, its name): said on the live
    /// line while it runs, never a row of its own.
    public var quiet = false
    /// A command or a path: cut in its middle. Words are cut at their end.
    public var middle = false
    /// Keys pressed: drawn as keys where there is room (the Mac's
    /// KeyGlyphs), else said by their names (`about`).
    public var keys: String?
    /// It waits on the person: said without the light, in the accent.
    public var asks = false

    public init(_ running: String, _ done: String, _ failed: String, _ object: String = "", _ art: StepArt,
                site: String? = nil, quiet: Bool = false, middle: Bool = false, keys: String? = nil, asks: Bool = false) {
        self.running = running
        self.done = done
        self.failed = failed
        self.object = object
        self.art = art
        self.site = site
        self.quiet = quiet
        self.middle = middle
        self.keys = keys
        self.asks = asks
    }

    /// The verb for a step's state: running (and stopped, where it was left
    /// going), done, failed.
    public func verb(_ state: String) -> String {
        let verb = state == "failed" ? failed : state == "done" ? done : running
        // With nothing after it, no word hangs off its end: "Searching the
        // web", not "Searching the web for".
        guard object.isEmpty, keys == nil else { return verb }
        for tail in [" for", " to", " at", " on", " in", ":"] where verb.hasSuffix(tail) { return String(verb.dropLast(tail.count)) }
        return verb
    }

    /// What it was about in words: keys by their names.
    public var about: String { keys.map(StepWords.keyWords) ?? object }

    /// The step in one line of words: "Opening github.com".
    public func line(_ state: String) -> String {
        about.isEmpty ? verb(state) : verb(state) + " " + about
    }
}

public extension StepWords {
    /// A step of a chat as sync carries it.
    static func of(_ item: SyncChatItem, place: StepPlace? = nil) -> StepWords {
        of(kind: item.kind, name: item.name, detail: item.detail, text: item.text, place: place)
    }

    /// A step of a chat, by its kind ("tool", "command", ...), its tool's
    /// name, what it was about and its words. `widget` is a widget's
    /// title, where the device has it.
    static func of(kind: String, name: String, detail: String, text: String, widget: String = "", place: StepPlace? = nil) -> StepWords {
        switch kind {
        case "command":
            return StepWords("Running", "Ran", "Couldn\u{2019}t run", command(detail), .command, middle: true)
        case "edit":
            return StepWords("Editing", "Edited", "Couldn\u{2019}t edit", detail, .edit, middle: true)
        case "subagent":
            var words: StepWords
            // A Codex subagent, by the action it performed.
            switch name {
            case "toParent": words = StepWords("Telling the main agent", "Told the main agent", "Couldn\u{2019}t tell the main agent", "", .robot, quiet: true)
            case "wait": words = StepWords("Waiting for a subagent", "Waited for a subagent", "Stopped waiting for a subagent", "", .robot)
            case "sendInput", "sendMessage", "followupTask": words = StepWords("Telling a subagent", "Told a subagent", "Couldn\u{2019}t tell a subagent", detail, .robot)
            case "closeAgent", "interruptAgent": words = StepWords("Stopping a subagent", "Stopped a subagent", "Couldn\u{2019}t stop a subagent", "", .robot)
            default: words = StepWords("Starting a subagent", "Started a subagent", "Couldn\u{2019}t start a subagent", detail, .robot)
            }
            words.site = host(detail)
            return words
        case "plan":
            return StepWords("Planning", "Planned", "Couldn\u{2019}t plan", "", .plan, quiet: true)
        case "chose":
            // Your answer to a question Codex asked in its turn.
            if name == "answered" { return StepWords("You answered:", "You answered:", "You answered:", text, .done) }
            return StepWords("You chose", "You chose", "You chose", text, .done)
        case "tool":
            return tool(name, detail: detail, outcome: text, place: place)
        case "widget":
            // Shown in the turn itself: said on the live line, never a row.
            return StepWords("Drawing", "Drew", "Couldn\u{2019}t draw", widgetWords(widget), .edit, quiet: true)
        default:
            // Thinking, words, a question: never a step.
            return StepWords("Thinking", "Thought", "Thought", "", .think, quiet: true)
        }
    }

    /// The tool Claude calls to read up before drawing a widget.
    static let readMe = "visualize/read_me"

    /// A widget's title in words: "flight_prices" as "flight prices".
    static func widgetWords(_ title: String) -> String {
        title.replacingOccurrences(of: "_", with: " ").split(separator: " ").joined(separator: " ")
    }

    /// A tool call, by its name and what it was about.
    static func tool(_ name: String, detail: String, outcome: String = "", place: StepPlace?) -> StepWords {
        let object = said(detail, place: place)
        let site = hosts(detail, place: place).first.map(bare)
        switch name {
        case "open":
            return StepWords("Opening", "Opened", "Couldn\u{2019}t open", object, .open, site: site)
        case "navigate":
            switch detail {
            case "nav:back": return StepWords("Going back", "Went back", "Couldn\u{2019}t go back", "", .open)
            case "nav:forward": return StepWords("Going forward", "Went forward", "Couldn\u{2019}t go forward", "", .open)
            case "nav:reload": return StepWords("Reloading the page", "Reloaded the page", "Couldn\u{2019}t reload the page", "", .open)
            default: return StepWords("Going to", "Went to", "Couldn\u{2019}t go to", object, .open, site: site)
            }
        case "fetch", "WebFetch":
            return StepWords("Reading", "Read", "Couldn\u{2019}t read", object, .open, site: site)
        case "snapshot", "text":
            return StepWords("Reading", "Read", "Couldn\u{2019}t read", object, .readPage)
        case "screenshot":
            return StepWords("Looking at", "Looked at", "Couldn\u{2019}t see", object, .shot)
        case "click":
            return StepWords("Clicking", "Clicked", "Couldn\u{2019}t click", object, .click)
        case "type":
            return StepWords("Typing", "Typed", "Couldn\u{2019}t type", object, .type)
        case "press":
            let keys = detail.hasPrefix("keys:") ? String(detail.dropFirst(5)) : detail
            return StepWords("Pressing", "Pressed", "Couldn\u{2019}t press", "", .type, keys: keys.isEmpty ? nil : keys)
        case "scroll":
            return StepWords("Scrolling", "Scrolled", "Couldn\u{2019}t scroll", object, .scroll)
        case "hover":
            return StepWords("Pointing at", "Pointed at", "Couldn\u{2019}t point at", object, .point)
        case "drag":
            return StepWords("Dragging", "Dragged", "Couldn\u{2019}t drag", object, .click)
        case "choose":
            return StepWords("Choosing", "Chose", "Couldn\u{2019}t choose", object, .click)
        case "dialog":
            return StepWords("Answering the page", "Answered the page", "Couldn\u{2019}t answer the page", object, .dialog)
        case "run", "eval":
            // A detail already said "on news.ycombinator.com": one "on".
            let place = object.hasPrefix("on ") ? String(object.dropFirst(3)) : object
            return StepWords("Running a script on", "Ran a script on", "Couldn\u{2019}t run a script on", place, .code)
        case "wait":
            return StepWords("Waiting for the page", "Waited for the page", "Gave up waiting for the page", "", .wait, quiet: true)
        case "close":
            return StepWords("Closing", "Closed", "Couldn\u{2019}t close", object.isEmpty ? "a tab" : object, .close)
        case "show":
            return StepWords("Showing you", "Showed you", "Couldn\u{2019}t show you", object.isEmpty ? "the tab" : object, .open, site: site)
        case "upload":
            return StepWords("Uploading", "Uploaded", "Couldn\u{2019}t upload", object, .upload)
        case "download":
            return StepWords("Downloading", "Downloaded", "Couldn\u{2019}t download", object, .download)
        case "pdf":
            return StepWords("Saving as PDF", "Saved as PDF", "Couldn\u{2019}t save as PDF", object, .pdf)
        case "save_page":
            return StepWords("Saving", "Saved", "Couldn\u{2019}t save", object.isEmpty ? "the page" : object, .pdf)
        case "autofill":
            return StepWords("Filling", "Filled", "Couldn\u{2019}t fill", object.isEmpty ? "the form" : object, .fill)
        case "boost":
            // A quiet try (Boosts.fit), by the site it changes and, once
            // answered, how many versions it took (ChatItem.boostTries).
            let tries = outcome.hasPrefix("tries:") ? Int(outcome.dropFirst(6)) ?? 1 : 1
            let done = tries > 1 ? "Tried \(tries) versions on" : "Tried a boost on"
            return StepWords("Trying a boost on", done, "Couldn\u{2019}t try a boost on", object, .edit, site: site)
        case "boosts":
            return StepWords("Reading your boosts", "Read your boosts", "Couldn\u{2019}t read your boosts", "", .readFile, quiet: true)
        case "boost_read":
            return StepWords("Reading the boost", "Read the boost", "Couldn\u{2019}t read the boost", object, .readFile, quiet: true)
        case "watch":
            return StepWords("Watching", "Watched", "Couldn\u{2019}t watch", object, .eye)
        case "watch_page":
            return StepWords("Setting a watch on", "Watching", "Couldn\u{2019}t watch", object.isEmpty ? "the page" : object, .eye)
        case "ask", "AskUserQuestion":
            return StepWords("Asking you", "Asked you", "Couldn\u{2019}t ask you", object, .hand, asks: true)
        case "handoff":
            // What came of it: you did it, you skipped it, or it went on
            // without an answer (Agents.handBack writes which).
            let done = outcome == "skipped" ? "You skipped:" : outcome == "done" ? "You finished:" : "Waited for you:"
            return StepWords("Waiting for you:", done, "Couldn\u{2019}t hand it to you:", object, .hand, asks: true)
        case "sign_in":
            return StepWords("Signing in to", "Signed in to", "Couldn\u{2019}t sign in to", object, .key)
        case "unlock_manager":
            return StepWords("Unlocking", "Unlocked", "Couldn\u{2019}t unlock", object.isEmpty ? "your password manager" : object, .key)
        case "computer_access":
            return StepWords("Asking to use your Mac", "Asked to use your Mac", "Couldn\u{2019}t use your Mac", object, .hand, asks: true)
        case "folder_access":
            return StepWords("Asking you to open", "Asked you to open", "Couldn\u{2019}t open", object, .hand, asks: true)
        case "mail_triage":
            return StepWords("Sorting your inbox", "Sorted your inbox", "Couldn\u{2019}t sort your inbox", "", .mail)
        case "mail_search":
            return StepWords("Searching mail for", "Searched mail for", "Couldn\u{2019}t search mail for", object, .mail)
        case "mail_recall":
            return StepWords("Searching all mail for", "Searched all mail for", "Couldn\u{2019}t search all mail for", object, .mail)
        case "mail_read":
            return StepWords("Reading mail", "Read mail", "Couldn\u{2019}t read mail", object, .mail)
        case "mail_file":
            return StepWords("Reading a file from mail", "Read a file from mail", "Couldn\u{2019}t read a file from mail", object, .mail)
        case "files_search":
            if object.isEmpty { return StepWords("Looking through your files", "Looked through your files", "Couldn\u{2019}t look through your files", "", .history) }
            return StepWords("Searching your files for", "Searched your files for", "Couldn\u{2019}t search your files for", object, .history)
        case "files_read":
            return StepWords("Reading a file", "Read a file", "Couldn\u{2019}t read a file", object, .history)
        case "purchases":
            return StepWords("Looking through your purchases", "Looked through your purchases", "Couldn\u{2019}t look through your purchases", "", .mail)
        case "mail_snippets":
            return StepWords("Reading your snippets", "Read your snippets", "Couldn\u{2019}t read your snippets", "", .mail)
        case "mail_draft":
            return StepWords("Writing a reply", "Wrote a reply", "Couldn\u{2019}t write a reply", object, .mail)
        case "mail_send":
            if detail == "undo:" { return StepWords("Taking back the mail", "Took back the mail", "Couldn\u{2019}t take back the mail", "", .mail) }
            return StepWords("Sending mail", "Sent mail", "Couldn\u{2019}t send mail", object, .send)
        case "mail_act":
            switch detail {
            case "unsubscribe:": return StepWords("Unsubscribing", "Unsubscribed", "Couldn\u{2019}t unsubscribe", "", .mail)
            case "remind:": return StepWords("Setting a reminder", "Set a reminder", "Couldn\u{2019}t set a reminder", "", .mail)
            case "unremind:": return StepWords("Removing a reminder", "Removed a reminder", "Couldn\u{2019}t remove a reminder", "", .mail)
            default: return StepWords("Tidying mail", "Tidied mail", "Couldn\u{2019}t tidy mail", object, .mail)
            }
        case "mail_list":
            let list = detail.hasPrefix("list:") ? String(detail.dropFirst(5)) : ""
            if list.isEmpty { return StepWords("Looking over your mail", "Looked over your mail", "Couldn\u{2019}t look over your mail", "", .mail, quiet: true) }
            return StepWords("Reading", "Read", "Couldn\u{2019}t read", "\u{201C}" + list + "\u{201D}", .mail, quiet: true)
        case "mail_accounts":
            let parts = detail.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let address = parts.count > 1 ? parts[1] : ""
            if parts.first == "add" {
                return StepWords("Connecting", "Started connecting", "Couldn\u{2019}t connect", address.isEmpty ? "a mail account" : address, .mail)
            }
            return StepWords("Reading your mail accounts", "Read your mail accounts", "Couldn\u{2019}t read your mail accounts", "", .mail, quiet: true)
        case "mail_labels":
            let parts = detail.split(separator: ":", maxSplits: 1).map(String.init)
            let what = parts.count > 1 ? parts[1] : ""
            let label = what.isEmpty ? "" : "\u{201C}" + String(what.prefix(60)) + "\u{201D}"
            switch parts.first {
            case "create": return StepWords("Making the label", "Made the label", "Couldn\u{2019}t make the label", label, .mail)
            case "rename": return StepWords("Renaming the label", "Renamed the label", "Couldn\u{2019}t rename the label", label, .mail)
            case "delete":
                if let count = Int(what) { return StepWords("Deleting \(count) labels", "Deleted \(count) labels", "Couldn\u{2019}t delete \(count) labels", "", .mail) }
                return StepWords("Deleting the label", "Deleted the label", "Couldn\u{2019}t delete the label", label, .mail)
            default: return StepWords("Reading your labels", "Read your labels", "Couldn\u{2019}t read your labels", "", .mail)
            }
        case "mail_code", "messages_code":
            return StepWords("Finding the code", "Found the code", "Couldn\u{2019}t find the code", object, .key)
        case "messages":
            return StepWords("Reading messages", "Read messages", "Couldn\u{2019}t read messages", object, .dialog)
        case "send_message":
            return StepWords("Sending a message", "Sent a message", "Couldn\u{2019}t send a message", object, .send)
        case "subagent":
            return StepWords("Starting a subagent", "Started a subagent", "Couldn\u{2019}t start a subagent", object, .robot)
        case "subagent_wait":
            return StepWords("Waiting for subagents", "Waited for subagents", "Stopped waiting for subagents", "", .robot)
        case "task", "task_queue":
            return StepWords("Starting a task", "Started a task", "Couldn\u{2019}t start a task", object, .robot)
        case "task_steer":
            return StepWords("Steering a task", "Steered a task", "Couldn\u{2019}t steer a task", object, .robot)
        case "task_stop":
            return StepWords("Stopping a task", "Stopped a task", "Couldn\u{2019}t stop a task", object, .robot)
        case "task_status":
            return StepWords("Checking on a task", "Checked on a task", "Couldn\u{2019}t check on a task", "", .robot, quiet: true)
        case "memory_search", "memory_read":
            return StepWords("Looking in memory", "Looked in memory", "Couldn\u{2019}t look in memory", "", .memory, quiet: true)
        case "remember":
            // Chats kept before a fact was said plainly hold its markdown, cut and quoted.
            let fact = StepProse.remembered(detail.trimmingCharacters(in: CharacterSet(charactersIn: "\u{201C}\u{201D}")))
            return StepWords("Remembering", "Remembered", "Couldn\u{2019}t remember", fact.isEmpty ? "" : "\u{201C}" + fact + "\u{201D}", .memory, quiet: true)
        case "history":
            return StepWords("Looking through your history", "Looked through your history", "Couldn\u{2019}t read your history", "", .history, quiet: true)
        case "devices":
            return StepWords("Looking at your devices", "Looked at your devices", "Couldn\u{2019}t see your devices", "", .history, quiet: true)
        case "calendar":
            return StepWords("Reading your calendar", "Read your calendar", "Couldn\u{2019}t read your calendar", "", .plan, quiet: true)
        case "calendar_add":
            return StepWords("Adding to your calendar", "Opened the event", "Couldn\u{2019}t open the event", object, .plan)
        case "calendar_free":
            return StepWords("Finding free time", "Found free time", "Couldn\u{2019}t find free time", "", .plan, quiet: true)
        case "skill", "skills", "Skill":
            return StepWords("Reading a skill", "Read a skill", "Couldn\u{2019}t read a skill", object, .skill, quiet: true)
        case "name":
            return StepWords("Naming the task", "Named the task", "Couldn\u{2019}t name the task", object, .edit, quiet: true)
        case "profile":
            return StepWords("Reading your profile", "Read your profile", "Couldn\u{2019}t read your profile", "", .fill, quiet: true)
        case "form_answers":
            return StepWords("Looking over saved answers", "Looked over saved answers", "Couldn\u{2019}t look over saved answers", "", .fill, quiet: true)
        case "keep_address":
            return StepWords("Keeping an address", "Kept an address", "Couldn\u{2019}t keep an address", "", .fill, quiet: true)
        case "know_report":
            return StepWords("Writing down what it learned", "Wrote down what it learned", "Couldn\u{2019}t write down what it learned", "", .edit, quiet: true)
        case "suggest":
            return StepWords("Writing suggestions", "Wrote suggestions", "Couldn\u{2019}t write suggestions", "", .plan, quiet: true)
        case "spaces", "tabs":
            return StepWords("Looking at your tabs", "Looked at your tabs", "Couldn\u{2019}t see your tabs", "", .close, quiet: true)
        case "Read", "NotebookRead":
            return StepWords("Reading", "Read", "Couldn\u{2019}t read", object, .readFile, middle: true)
        case "Grep":
            return StepWords("Searching for", "Searched for", "Couldn\u{2019}t search for", object, .search)
        case "Glob", "LS":
            return StepWords("Listing", "Listed", "Couldn\u{2019}t list", object, .folder, middle: true)
        case "WebSearch", "web_search":
            return StepWords("Searching the web for", "Searched the web for", "Couldn\u{2019}t search the web for", object, .search)
        // Codex's web tool finding words in a page it read, and its other looks.
        case "web_find":
            return StepWords("Finding", "Found", "Couldn\u{2019}t find", object, .search)
        case "web_other":
            return StepWords("Looking on the web", "Looked on the web", "Couldn\u{2019}t look on the web", "", .search, quiet: true)
        // One of Codex's commands reading, searching and listing at once
        // (ChatItem.codexRun).
        case "explored", "explore":
            return StepWords("Exploring:", "Explored:", "Couldn\u{2019}t explore:", object, .search)
        case "ToolSearch":
            return StepWords("Looking for tools", "Looked for tools", "Couldn\u{2019}t find tools", "", .search, quiet: true)
        case "BashOutput":
            return StepWords("Reading a command\u{2019}s output", "Read a command\u{2019}s output", "Couldn\u{2019}t read a command\u{2019}s output", "", .command)
        case "KillShell", "KillBash":
            return StepWords("Stopping a command", "Stopped a command", "Couldn\u{2019}t stop a command", "", .command)
        case "ExitPlanMode":
            return StepWords("Writing a plan", "Wrote a plan", "Couldn\u{2019}t write a plan", "", .plan)
        case "SlashCommand":
            return StepWords("Running", "Ran", "Couldn\u{2019}t run", object, .command)
        // Claude Code's and Codex's own tools.
        case "Artifact":
            return StepWords("Publishing a page", "Published a page", "Couldn\u{2019}t publish a page", object, .open)
        case "SendUserFile":
            return StepWords("Sending you a file", "Sent you a file", "Couldn\u{2019}t send you a file", object, .upload)
        case "SendMessage":
            return StepWords("Telling a subagent", "Told a subagent", "Couldn\u{2019}t tell a subagent", object, .robot)
        case "Monitor":
            return StepWords("Watching:", "Watched:", "Couldn\u{2019}t watch:", object, .eye)
        case "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskStop", "TaskOutput", "ListAgents", "ReadNotifications", "list_agents", "SubagentHandback":
            return StepWords("Checking on its tasks", "Checked on its tasks", "Couldn\u{2019}t check on its tasks", "", .robot, quiet: true)
        case "ScheduleWakeup" where !detail.isEmpty:
            // "Back in 20 min: check the CI run" (ChatItem.wakeup).
            return StepWords("Coming back", "Back", "Couldn\u{2019}t set a time to come back", detail, .wait)
        case "ScheduleWakeup", "CronCreate":
            return StepWords("Setting a time to come back", "Set a time to come back", "Couldn\u{2019}t set a time to come back", "", .wait)
        case "Workflow":
            return StepWords("Running a workflow:", "Ran a workflow:", "Couldn\u{2019}t run a workflow:", object, .robot)
        case "ReportFindings":
            return StepWords("Writing up findings", "Wrote up findings", "Couldn\u{2019}t write up findings", "", .edit)
        case "EnterWorktree":
            return StepWords("Going to a worktree", "Went to a worktree", "Couldn\u{2019}t go to a worktree", object, .folder)
        case "ExitWorktree":
            return StepWords("Leaving the worktree", "Left the worktree", "Couldn\u{2019}t leave the worktree", "", .folder)
        case "PushNotification":
            return StepWords("Notifying you", "Notified you", "Couldn\u{2019}t notify you", object, .send)
        case "EnterPlanMode":
            return StepWords("Planning", "Planned", "Couldn\u{2019}t plan", "", .plan)
        case "write_stdin":
            return StepWords("Typing into a command", "Typed into a command", "Couldn\u{2019}t type into a command", "", .command)
        case "view_image":
            return StepWords("Looking at", "Looked at", "Couldn\u{2019}t see", object, .shot, middle: true)
        case "image_gen", "imagegen":
            return StepWords("Making an image", "Made an image", "Couldn\u{2019}t make an image", object, .shot)
        case "web":
            return StepWords("Searching the web", "Searched the web", "Couldn\u{2019}t search the web", object, .search)
        case "clock", "sleep", "curr_time":
            return StepWords("Waiting", "Waited", "Gave up waiting", "", .wait, quiet: true)
        case "js", "script", "node_repl":
            return StepWords("Running a script", "Ran a script", "Couldn\u{2019}t run a script", object, .code)
        case "untrusted_input":
            return StepWords("Reading what came in", "Read what came in", "Couldn\u{2019}t read what came in", "", .readFile, quiet: true)
        case readMe:
            return StepWords("Getting ready to draw", "Got ready to draw", "Couldn\u{2019}t get ready to draw", "", .edit, quiet: true)
        // The CLI's own goings on, said on the live line (Agents, ChatItem.codexSteps).
        case "retry":
            return StepWords("Retrying,", "Retried,", "Gave up retrying,", object, .wait, quiet: true)
        case "compact":
            return StepWords("Compacting the conversation", "Compacted the conversation", "Couldn\u{2019}t compact the conversation", "", .memory, quiet: true)
        case "hook":
            return StepWords("Running a hook", "Ran a hook", "Couldn\u{2019}t run a hook", "", .command, quiet: true)
        case "update_goal", "create_goal", "get_goal":
            return StepWords("Setting its goal", "Set its goal", "Couldn\u{2019}t set its goal", "", .plan, quiet: true)
        default:
            if let slash = name.firstIndex(of: "/") {
                return server(String(name[..<slash]), String(name[name.index(after: slash)...]), object: object)
            }
            let words = spoken(name)
            return StepWords("Using \(words)", "Used \(words)", "Couldn\u{2019}t use \(words)", object, .mcp)
        }
    }

    // MARK: - what it was about

    /// A step's detail as the line says it: a tab by its page's title,
    /// several sites as "tabelog.com and 2 more", keys by their names. A
    /// tab the device doesn't know is said without.
    static func said(_ detail: String, place: StepPlace?) -> String {
        if detail.hasPrefix("tab:") {
            guard let place else { return "" }
            return title(place.title, host: place.host) ?? bare(place.host ?? "")
        }
        if detail.hasPrefix("nav:") { return "" }
        if detail.hasPrefix("keys:") { return String(detail.dropFirst(5)) }
        let hosts = hosts(detail, place: nil).map(bare)
        guard hosts.count > 1 else { return hosts.first ?? detail }
        return hosts.count == 2 ? hosts.joined(separator: " and ") : "\(hosts[0]) and \(hosts.count - 1) more"
    }

    /// A page's title without its site's name on the end: "Sign in to
    /// GitHub · GitHub" is "Sign in to GitHub". Nil for no title.
    static func title(_ title: String, host: String?) -> String? {
        let words = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        let core = (host.map(bare) ?? "").split(separator: ".").first.map { String($0).lowercased() } ?? ""
        for mark in [" \u{00B7} ", " | ", " - ", " \u{2014} ", " \u{2013} "] {
            guard let cut = words.range(of: mark, options: .backwards) else { continue }
            let tail = words[cut.upperBound...].lowercased().replacingOccurrences(of: " ", with: "")
            let head = String(words[..<cut.lowerBound])
            guard !head.isEmpty, !core.isEmpty else { continue }
            if tail.contains(core) || core.contains(tail) { return head }
        }
        return words
    }

    /// A command as a person would read it: a shell's wrapper taken off.
    static func command(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:/(?:usr/)?bin/)?(?:ba|z)?sh\s+-l?c\s+(['"])([\s\S]*)\1$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let inner = Range(match.range(at: 2), in: trimmed) else { return trimmed }
        return String(trimmed[inner]).replacingOccurrences(of: "'\\''", with: "'")
    }

    /// A step's detail when it names a site's host.
    static func host(_ detail: String) -> String? {
        guard detail.contains("."), !detail.contains(" "), !detail.contains("/"), detail.count < 80 else { return nil }
        return detail
    }

    /// The hosts a detail names: one, or several joined by commas; a tab's
    /// site, where the device knows it.
    static func hosts(_ detail: String, place: StepPlace?) -> [String] {
        if detail.hasPrefix("tab:") { return place?.site.map { [$0] } ?? [] }
        return detail.components(separatedBy: ", ").compactMap(host)
    }

    static func bare(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

    /// Keys in words, for where they can't be drawn: "Return", "⌘A".
    static func keyWords(_ keys: String) -> String {
        keys.split(separator: " ").map { key in
            switch key.lowercased() {
            case "enter", "return": return "Return"
            case "escape", "esc": return "Esc"
            case "tab": return "Tab"
            case "backspace": return "Delete"
            default: return String(key)
            }
        }.joined(separator: " ")
    }

    /// A tool's own name said as words: "create_issue" as "create issue".
    static func spoken(_ name: String) -> String {
        var words = ""
        for character in name {
            if character == "_" || character == "-" { words.append(" ") }
            else if character.isUppercase, let last = words.last, last.isLowercase { words.append(" "); words.append(Character(character.lowercased())) }
            else { words.append(character) }
        }
        return words.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - other servers' tools

    /// A tool of another MCP server, said as what it did and where:
    /// linear's create_issue is "Created an issue in Linear".
    static func server(_ server: String, _ tool: String, object: String) -> StepWords {
        let place = serverName(server)
        let site = serverSites[server.lowercased()]
        let tokens = spoken(tool).lowercased().split(separator: " ").map(String.init)
        guard let first = tokens.first, let verb = verbs[first] else {
            let words = spoken(tool)
            return StepWords("Using \(place)", "Used \(place)", "Couldn\u{2019}t use \(place)", words.isEmpty ? object : object.isEmpty ? words : object,
                             site == nil ? .mcp : .open, site: site)
        }
        // Two verbs and their noun, GitHub's create_or_update_file: "Created
        // or updated a file", not "Created an or update file".
        var said = (verb: verb, base: first, noun: tokens.dropFirst())
        if tokens.count > 2, tokens[1] == "or" || tokens[1] == "and", let second = verbs[tokens[2]] {
            let join = " " + tokens[1] + " "
            said = ((verb.0 + join + second.0.lowercased(), verb.1 + join + second.1.lowercased()),
                    first + join + tokens[2], tokens.dropFirst(3))
        }
        let noun = said.noun.joined(separator: " ")
        let thing = noun.isEmpty ? "" : article(noun) + " "
        let tail = "\(thing)in \(place)"
        return StepWords("\(said.verb.0) \(tail)", "\(said.verb.1) \(tail)", "Couldn\u{2019}t \(said.base) \(tail)", object,
                         site == nil ? .mcp : .open, site: site)
    }

    private static func article(_ noun: String) -> String {
        if noun.hasSuffix("s") && !noun.hasSuffix("ss") { return noun }
        return (vowelSound(noun) ? "an " : "a ") + noun
    }

    /// Whether a noun starts with a vowel's sound, which is what takes
    /// "an": an issue, an hour, but a user, a URL, a one-time code. The
    /// words tools are named with that are said otherwise than spelled.
    static func vowelSound(_ noun: String) -> Bool {
        let word = noun.prefix { $0 != " " }
        if ["hour", "honest", "honor", "heir"].contains(where: { word.hasPrefix($0) }) { return true }
        if ["user", "usage", "use", "url", "uri", "uuid", "unit", "union", "unique", "utility", "one", "once", "euro"]
            .contains(where: { word.hasPrefix($0) }) { return false }
        return "aeiou".contains(word.first ?? "x")
    }

    static func serverName(_ server: String) -> String {
        let known = ["github": "GitHub", "gitlab": "GitLab", "hubspot": "HubSpot", "aws": "AWS", "google-calendar": "Google Calendar",
                     "google-drive": "Google Drive", "gmail": "Gmail", "atlassian": "Jira", "jira": "Jira", "posthog": "PostHog", "clickup": "ClickUp"]
        if let name = known[server.lowercased()] { return name }
        return server.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static let serverSites: [String: String] = [
        "linear": "linear.app", "github": "github.com", "gitlab": "gitlab.com", "slack": "slack.com", "notion": "notion.so",
        "figma": "figma.com", "gmail": "mail.google.com", "google-calendar": "calendar.google.com", "google-drive": "drive.google.com",
        "sentry": "sentry.io", "stripe": "stripe.com", "vercel": "vercel.com", "supabase": "supabase.com", "atlassian": "atlassian.com",
        "jira": "atlassian.com", "asana": "asana.com", "hubspot": "hubspot.com", "intercom": "intercom.com", "airtable": "airtable.com",
        "cloudflare": "cloudflare.com", "zapier": "zapier.com", "posthog": "posthog.com", "clickup": "clickup.com", "canva": "canva.com",
    ]

    static let verbs: [String: (String, String)] = [
        "create": ("Creating", "Created"), "get": ("Getting", "Got"), "list": ("Listing", "Listed"), "search": ("Searching", "Searched"),
        "find": ("Finding", "Found"), "update": ("Updating", "Updated"), "edit": ("Editing", "Edited"), "delete": ("Deleting", "Deleted"),
        "remove": ("Removing", "Removed"), "add": ("Adding", "Added"), "send": ("Sending", "Sent"), "read": ("Reading", "Read"),
        "fetch": ("Fetching", "Fetched"), "post": ("Posting", "Posted"), "comment": ("Commenting on", "Commented on"), "run": ("Running", "Ran"),
        "query": ("Querying", "Queried"), "open": ("Opening", "Opened"), "close": ("Closing", "Closed"), "move": ("Moving", "Moved"),
        "assign": ("Assigning", "Assigned"), "upload": ("Uploading", "Uploaded"), "download": ("Downloading", "Downloaded"),
        "write": ("Writing", "Wrote"), "set": ("Setting", "Set"), "start": ("Starting", "Started"), "stop": ("Stopping", "Stopped"),
        "cancel": ("Canceling", "Canceled"), "schedule": ("Scheduling", "Scheduled"), "invite": ("Inviting", "Invited"),
        "reply": ("Replying to", "Replied to"), "merge": ("Merging", "Merged"), "review": ("Reviewing", "Reviewed"),
        "publish": ("Publishing", "Published"), "check": ("Checking", "Checked"), "view": ("Viewing", "Viewed"),
    ]
}

// MARK: - markdown as words

/// An agent's markdown as plain words, for what a step says it remembered
/// and what the Mac's chat takes from a stream (ChatItem.prose).
public enum StepProse {
    /// Words an agent wrote in markdown, as one line of plain words: no
    /// heading, list or quote marks, no bold, italics or code ticks, links
    /// as their words, its lines joined. Only for prose: what was typed,
    /// searched for or run keeps every character.
    public static func prose(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines).map { line -> String in
            var line = line.trimmingCharacters(in: .whitespaces)
            for mark in [#"^#{1,6}\s+"#, #"^>\s*"#, #"^(?:[-*+•]|\d{1,3}[.)])\s+"#, #"^\[[ xX>]\]\s+"#] {
                line = line.replacingOccurrences(of: mark, with: "", options: .regularExpression)
            }
            return line
                .replacingOccurrences(of: #"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"(\*\*|__|~~)(.+?)\1"#, with: "$2", options: .regularExpression)
                .replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*\n]+?)\*(?![\w*])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"(?<![\w_])_(?!\s)([^_\n]+?)_(?![\w_])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "`", with: "")
        }
        return lines.filter { !$0.isEmpty && !$0.allSatisfy { "-*_=|: ".contains($0) } }.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// What a `remember` keeps, in a few words: a new page's own
    /// description (its frontmatter), else its first fact, the headings
    /// over it and a table's rows passed by; a heading only when there is
    /// nothing under it.
    public static func remembered(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if let open = lines.firstIndex(where: { !$0.isEmpty }), lines[open] == "---",
           let close = lines[(open + 1)...].firstIndex(of: "---") {
            let front = lines[(open + 1)..<close]
            for key in ["description:", "name:"] {
                guard let line = front.first(where: { $0.hasPrefix(key) }) else { continue }
                let value = line.dropFirst(key.count).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
                if !value.isEmpty { return prose(value) }
            }
            lines = Array(lines[(close + 1)...])
        }
        let fact = lines.first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("|") && !prose($0).isEmpty }
        return prose(fact ?? lines.first { !prose($0).isEmpty } ?? "")
    }
}
