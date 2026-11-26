import Testing
@testable import Fast

/// `open` that came to nothing says what Yab said: a refused or unheard
/// call read as "could not open <url>", and agents gave up on the site.
struct McpOpenSaysWhyTests {
    @Test func whatYabSaidIsKept() {
        let url = "https://example.com/"
        #expect(Mcp.notOpened(url, said: nil) == "could not open https://example.com/")
        #expect(Mcp.notOpened(url, said: "") == "could not open https://example.com/")
        #expect(Mcp.notOpened(url, said: BenchCaller.refusal)
            == "could not open https://example.com/: Only Yab's own yab command and yab mcp can use Yab's socket.")
        #expect(Mcp.notOpened(url, said: "Yab isn't running.") == "could not open https://example.com/: Yab isn't running.")
        // Already said in the same words: not twice.
        #expect(Mcp.notOpened(url, said: "could not open that space's store") == "could not open that space's store")
    }

    @Test func onlyAnOpenThatReachedYabIsTriedAgain() {
        for unreached in [BenchCaller.refusal, "Yab isn't running.", "This task's permission expired.",
                          "This task's permission expired. Start a new task.", ContextConsent.unavailable,
                          "Yab is open, but agents are off: turn on Yab › Settings › Developers › “Let agents use Yab”.",
                          "Agents are off in Yab: run `yab setup command`, or turn on Yab › Settings › Developers › “Let agents use Yab”."] {
            #expect(Mcp.unreached(unreached), "\(unreached)")
        }
        for reached in ["open needs a url", "no tab “abc”, see tabs", "a leftover tab went away"] {
            #expect(!Mcp.unreached(reached), "\(reached)")
        }
    }
}
