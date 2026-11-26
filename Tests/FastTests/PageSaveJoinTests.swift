import Testing
@testable import Fast

/// save_page's choice between one tab saved as itself and several tabs
/// joined into one file (AgentBenchPage.handleAgentPdf).
struct PageSaveJoinTests {
    @Test func markdownAndTextAreJoinedOnlyFromTwoTabs() {
        for format in ["md", "txt"] {
            #expect(!PageSave.joinsTabs(format: format, count: 1))
            #expect(PageSave.joinsTabs(format: format, count: 2))
            #expect(PageSave.joinsTabs(format: format, count: 5))
        }
    }

    @Test func otherFormatsAreNeverJoinedHere() {
        for format in ["pdf", "html", "csv", "xlsx", "png", "webarchive"] {
            #expect(!PageSave.joinsTabs(format: format, count: 1))
            #expect(!PageSave.joinsTabs(format: format, count: 3))
        }
    }
}
