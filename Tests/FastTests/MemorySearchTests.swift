import Foundation
import Testing
@testable import Fast

// Memory search (Memory.search): a hit names the page and the line its
// paragraph starts on, which `yab memory search` prints as file:line.
struct MemorySearchTests {
    @Test func aHitSaysTheLineItsParagraphStartsOn() throws {
        try #require(Store.testing)
        let name = "concepts/search-line-" + UUID().uuidString.prefix(8).lowercased()
        let url = try #require(Memory.file(name))
        let page = "# Search Line\n\n## Current\n\nQuokkas live on Rottnest Island.\n\n- Quokkas are marsupials.\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try page.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = page.components(separatedBy: "\n")
        let hits = Memory.search(["rottnest", "marsupials"]).filter { $0.file == name + ".md" }
        #expect(hits.count == 2)
        for hit in hits {
            #expect(lines[hit.line - 1] == hit.text, "a paragraph after a blank line starts on its own first line")
        }
    }
}
