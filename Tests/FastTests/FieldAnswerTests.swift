import Foundation
import Testing
@testable import Fast

/// A command's answer in the field: what a rewrite marks, and how an
/// answer's Markdown is drawn.
struct FieldAnswerTests {
    @Test func explicitOpenCommandsKeepTheAddressAndIgnoreDescription() {
        #expect(TaskWords.openingURL("open espn.com/soccer: news, recaps, streams.")?.absoluteString == "https://espn.com/soccer")
        #expect(TaskWords.openingURL("Open https://example.test/news?q=football#today")?.absoluteString == "https://example.test/news?q=football#today")
        #expect(TaskWords.openingURL("please, open the site example.test in a new tab")?.host() == "example.test")
        #expect(TaskWords.openingURL("Could you open example.test")?.host() == "example.test")
        for text in ["How do I open espn.com/soccer?", "Explain how to open example.test", "open example.test and buy tickets", "open javascript:alert(1)", "open file:///tmp/private", "open https://user:secret@example.test", "<invoke name=\"open\">example.test</invoke>"] {
            #expect(TaskWords.openingURL(text) == nil, "\(text)")
        }
    }

    @MainActor @Test func openFollowUpCreatesOneOrdinaryTabWithoutAnAgent() {
        let id = UUID(), browser = Browser(windowID: id)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        let sessions = Set(Agents.shared.sessions.map(\.id)), count = browser.tabs.count
        browser.selectionCommands.command = SelectionCommand(id: "ask", name: "Ask", prompt: "Football sites", executor: "agent", custom: true)
        browser.selectionCommands.snapshot = SelectionSnapshot(asking: nil)
        browser.selectionCommands.answering = true
        browser.selectionCommands.output = "Sports results"
        browser.selectionCommands.stage = .preview
        browser.replaceTyped("open example.test/soccer: news, recaps, streams.")
        let action = browser.answerActions.first { $0.id == "follow" }
        #expect(action != nil)
        action?.run()
        #expect(browser.tabs.count == count + 1)
        #expect(browser.active?.address?.absoluteString == "https://example.test/soccer")
        #expect(browser.active?.bench == false && browser.active?.agent == nil)
        #expect(browser.selectionCommands.stage == .closed)
        #expect(Set(Agents.shared.sessions.map(\.id)) == sessions)
        if let tab = browser.active { browser.close(tab) }
    }

    @MainActor @Test func initialAskOpenPreservesPrivateBrowsing() throws {
        let id = UUID(), browser = Browser(windowID: id)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        let source = Tab(shy: true, configuration: Web.configuration(shy: true))
        browser.lay([source]); browser.select(source)
        let sessions = Set(Agents.shared.sessions.map(\.id))
        browser.askInField("open https://example.test/private")
        let opened = try #require(browser.active)
        #expect(opened !== source && opened.shy)
        #expect(opened.store === source.store)
        #expect(opened.address?.absoluteString == "https://example.test/private")
        #expect(Set(Agents.shared.sessions.map(\.id)) == sessions)
        browser.close(opened)
        browser.close(source)
    }

    @Test @MainActor func rewriteCountsEachChangedRun() {
        let (_, changes) = FieldAnswerDiff.mark("40k is to much for us", "40k is too much for us")
        #expect(changes == 1)
        let (_, two) = FieldAnswerDiff.mark("hi alex, see you tuesday", "Hi Alex, see you Tuesday")
        #expect(two == 2)
    }

    @Test @MainActor func unchangedAndMixedScriptsMarkNothingWrong() {
        #expect(FieldAnswerDiff.mark("same words", "same words").changes == 0)
        let (text, changes) = FieldAnswerDiff.mark("we can 🙂 你好", "we can 🙂 你好 שלום")
        #expect(changes == 1)
        #expect(String(text.characters) == "we can 🙂 你好 שלום")
    }

    @Test @MainActor func longRewriteIsNotMarked() {
        let long = Array(repeating: "word", count: FieldAnswerDiff.most).joined(separator: " ")
        let (text, changes) = FieldAnswerDiff.mark(long, long + " more")
        #expect(changes == nil)
        #expect(String(text.characters) == long + " more")
    }

    @Test @MainActor func fencedCodeKeepsItsLines() {
        let shaped = String(AgentAnswer.rich("Before\n```swift\nlet a = 1\nprint(a)\n```\nAfter").characters)
        #expect(shaped == "Before\nlet a = 1\nprint(a)\nAfter")
    }

    @Test @MainActor func tableLosesItsRuleAndPipes() {
        let shaped = String(AgentAnswer.rich("| Step | Before |\n|---|:---:|\n| Plan | 2nd |").characters)
        #expect(shaped == "Step   Before\nPlan   2nd")
    }

    @Test @MainActor func bulletedBoldMarkdownRendersWithoutRawSyntax() {
        let input = """
        Someone just spent **$665,000** buying stock options on **$ANT**.

        * **$ANT:** The stock symbol.
        - **$10 puts:** A **put option** at **$10 per share**, even lower.
        """
        let rich = AgentAnswer.rich(input)
        let plain = String(rich.characters)
        #expect(!plain.contains("**"))
        #expect(plain.contains("• $ANT: The stock symbol."))
        #expect(plain.contains("• $10 puts: A put option at $10 per share, even lower."))
        let boldRuns = rich.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(rich[$0.range].characters) }
        #expect(boldRuns.contains("$665,000"))
        #expect(boldRuns.contains("$ANT:"))
        #expect(boldRuns.contains("put option"))
    }

    @Test @MainActor func selectionDockKeepsRewritePreviewsLiteralAndFormatsAnswers() throws {
        let commands = SelectionCommands()
        let markdown = "# Release notes\n- Ship **Friday**"
        commands.output = markdown
        commands.stage = .preview
        commands.command = try #require(SelectionCommand.builtIn.first { $0.id == "improve" })
        #expect(String(SelectionDockContent.displayText(commands).characters) == markdown)

        commands.command = try #require(SelectionCommand.builtIn.first { $0.id == "explain" })
        let rendered = String(SelectionDockContent.displayText(commands).characters)
        #expect(rendered == "Release notes\n• Ship Friday")

        commands.stage = .failed
        commands.error = "**raw error**"
        #expect(String(SelectionDockContent.displayText(commands).characters) == "**raw error**")
    }
}
