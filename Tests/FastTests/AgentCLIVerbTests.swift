import Testing
@testable import Fast

struct AgentCLIVerbTests {
    @Test func aTaskThatStartsWithAVerbIsATask() {
        for word in ["list", "stop", "steer", "queue", "memory"] {
            #expect(!AgentCLI.isVerb(word, first: true, verbs: false))
            #expect(AgentCLI.isVerb(word, first: true, verbs: true))
        }
    }

    @Test func aVerbCountsOnlyAsTheFirstWord() {
        #expect(!AgentCLI.isVerb("list", first: false, verbs: true))
        #expect(!AgentCLI.isVerb("summarize", first: true, verbs: true))
    }
}

struct CliSocketWordsTests {
    @Test func whereToReachYabIsNotAWord() {
        #expect(Cli.unsocketed(["mcp", "--socket", "/tmp/y.sock"]) == ["mcp"])
        #expect(Cli.unsocketed(["--socket", "/tmp/y.sock", "chrome"]) == ["chrome"])
        #expect(Cli.unsocketed(["claude"]) == ["claude"])
        #expect(Cli.unsocketed(["--socket"]) == [])
    }
}
