import AppKit
import XCTest
@testable import Fast

/// A picture's words as Copy Text and ⌘F take them: line by line, in
/// order, each word with a box inside the picture that stands where the
/// word was drawn.
final class PictureWordsTests: XCTestCase {
    /// A terminal's screenshot: light words on a dark ground, three lines.
    private func screenshot() -> CGImage {
        let size = NSSize(width: 900, height: 300)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1).setFill()
            rect.fill()
            let font = NSFont.monospacedSystemFont(ofSize: 30, weight: .regular)
            for (i, line) in ["~ % brew install yab", "~ % yab mcp add claude", "Added yab to Claude Code"].enumerated() {
                (line as NSString).draw(at: NSPoint(x: 40, y: 40 + CGFloat(i) * 80),
                                        withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.88, alpha: 1)])
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testLinesComeInOrder() async {
        let words = await PictureWords.read(screenshot(), whole: true)
        let lines = words.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, words.text)
        guard lines.count == 3 else { return }
        XCTAssertTrue(lines[1].contains("yab mcp add claude"), words.text)
        XCTAssertTrue(lines[2].hasPrefix("Added yab"), words.text)
        XCTAssertTrue(words.whole)
    }

    func testBoxesStandWhereTheWordsWere() async throws {
        let words = await PictureWords.read(screenshot(), whole: true)
        let mcp = try XCTUnwrap(words.lines.joined().first { $0.text == "mcp" })
        // The second line, drawn from 120 to about 160 of 300 down.
        XCTAssertGreaterThan(mcp.box.minY, 0.3)
        XCTAssertLessThan(mcp.box.maxY, 0.62)
        let claude = try XCTUnwrap(words.lines.dropFirst().first?.last)
        XCTAssertGreaterThan(claude.box.minX, mcp.box.maxX)
        guard words.script.count > 1 else { return XCTFail("one line read: \(words.text)") }
        XCTAssertEqual(words.script[1].map { $0["t"] as? String }, words.lines[1].map(\.text))
    }

    /// Two pieces Vision gave for one line, a wide gap between them, read as
    /// one line; a piece below starts the next.
    func testPiecesOfOneLineAreOneLine() {
        func word(_ text: String, _ x: CGFloat, _ y: CGFloat) -> PictureWords.Word {
            PictureWords.Word(text: text, box: CGRect(x: x, y: y, width: 0.1, height: 0.05))
        }
        let rows = PictureWords.rows([
            [word("connected", 0.4, 0.5)],
            [word("Added", 0.1, 0.2), word("yab", 0.22, 0.2)],
            [word("claude", 0.1, 0.505)],
            [word("(user", 0.5, 0.198)],
        ])
        XCTAssertEqual(rows.map { $0.map(\.text).joined(separator: " ") }, ["Added yab (user", "claude connected"])
    }

    func testAPictureWithoutWordsHasNone() async {
        let blank = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let words = await PictureWords.read(blank.cgImage(forProposedRect: nil, context: nil, hints: nil)!, whole: false)
        XCTAssertTrue(words.isEmpty)
        XCTAssertEqual(words.text, "")
    }
}
