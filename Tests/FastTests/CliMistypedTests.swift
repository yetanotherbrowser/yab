import Testing
@testable import Fast

/// `yab WORD` with a word that is no command used to start an agent task.
struct CliMistypedTests {
    @Test(arguments: [["feedback", "--help"], ["feedback", "-h"], ["open", "tabs", "--help"], ["summarize", "--help"],
                      // Joined names no task is written as.
                      ["list-tabs"], ["list_tabs"], ["List-Tabs"], ["list-tabs", "--socket", "/tmp/yab.sock"],
                      // A command's near misses, in any case.
                      ["sesion"], ["stauts"], ["memroy"], ["Stauts"], ["lsit"], ["sessoins"], ["agents"], ["guides"]])
    func mistypedCommandIsNotATask(args: [String]) {
        #expect(Cli.mistyped(args) == args[0])
    }

    @Test(arguments: [["find the unread message from Alex in Slack"], ["summarize", "my", "tabs"],
                      // A one-word task, lowercase or not.
                      ["continue"], ["Continue"], ["summarize"], ["Summarize"], ["tabs"], ["retry"],
                      // Near a command's letters, but a word of its own.
                      ["email"], ["save"], ["very"], ["hello"],
                      ["what's new?"], ["https://example.com"], [],
                      // What only `yab agent` answers itself.
                      ["list"], ["stop", "a1b2"], ["steer", "a1b2", "slower"], ["memory"],
                      // A flag first is the task's own, or a mistake the agent names.
                      ["--model", "opus", "tabs"]])
    func sentencesStayTasks(args: [String]) {
        #expect(Cli.mistyped(args) == nil)
    }

    /// A one-word follow-up to a session was refused as a mistyped command:
    /// resume reaches its own command, and the words it hands the agent are
    /// never asked.
    @Test(arguments: [["session", "resume", "a1b2", "yes"], ["sessions", "resume", "a1b2", "yes", "--socket", "/tmp/yab.sock"]])
    func resumeFollowUpIsNotRefused(args: [String]) {
        #expect(Cli.command(args) == args[0])
        #expect(Cli.mistyped(["--resume", "a1b2", "yes"]) == nil)
    }

    /// `yab agent WORD` is a task as typed: only a bare `yab WORD` is asked.
    @Test func agentWordsAreATask() {
        #expect(Cli.command(["agent", "tabs"]) == "agent")
    }

    /// `yab settings` is the command only before a verb, a flag or nothing: the rest is a task.
    @Test func settingsIsACommandOnlyBeforeAVerb() {
        #expect(Cli.command(["settings", "make", "it", "dark"]) == "")
        #expect(Cli.command(["settings", "--socket", "s", "show"]) == "settings")
        #expect(Cli.command(["settings"]) == "settings")
    }
}
